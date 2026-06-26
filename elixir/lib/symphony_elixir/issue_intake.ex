defmodule SymphonyElixir.IssueIntake do
  @moduledoc """
  Runtime issue/feature intake workflow for the private dashboard.
  """

  use GenServer

  alias SymphonyElixir.{Config, Linear.Client}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @max_sessions 25
  @max_messages 60

  @project_lookup_query """
  query SymphonyIssueIntakeProject($projectSlug: String!) {
    projects(filter: {slugId: {eq: $projectSlug}}, first: 1) {
      nodes {
        id
        name
        slugId
        url
        teams(first: 20) {
          nodes {
            id
            key
            name
            states(first: 50) {
              nodes {
                id
                name
              }
            }
          }
        }
      }
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyIssueIntakeCreateIssue(
    $teamId: String!
    $projectId: String!
    $title: String!
    $description: String!
    $stateId: String
  ) {
    issueCreate(
      input: {
        teamId: $teamId
        projectId: $projectId
        title: $title
        description: $description
        stateId: $stateId
      }
    ) {
      success
      issue {
        id
        identifier
        title
        url
        state {
          name
        }
      }
    }
  }
  """

  defstruct sessions: [], next_id: 1, scans: %{}

  @type session :: %{
          id: pos_integer(),
          kind: String.t(),
          title: String.t(),
          original_request: String.t(),
          status: String.t(),
          messages: [map()],
          scan: map() | nil,
          draft: String.t(),
          created_issue: map() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @spec list(non_neg_integer()) :: [session()]
  def list(limit \\ @max_sessions) do
    call_or_default({:list, limit}, [])
  end

  @spec get(pos_integer() | String.t()) :: session() | nil
  def get(session_id), do: call_or_default({:get, normalize_id(session_id)}, nil)

  @spec start_session(map()) :: {:ok, session()} | {:error, term()}
  def start_session(attrs) when is_map(attrs) do
    call_or_default({:start_session, attrs}, {:error, :unavailable})
  end

  @spec append_message(pos_integer() | String.t(), String.t()) :: {:ok, session()} | {:error, term()}
  def append_message(session_id, body) do
    call_or_default({:append_message, normalize_id(session_id), body}, {:error, :unavailable})
  end

  @spec create_linear_issue(pos_integer() | String.t()) :: {:ok, session()} | {:error, term()}
  def create_linear_issue(session_id) do
    call_or_default({:create_linear_issue, normalize_id(session_id)}, {:error, :unavailable})
  end

  @doc false
  def build_draft_for_test(session), do: build_draft(session)

  @doc false
  def scan_repository_for_test(repo_url, branch), do: scan_repository(repo_url, branch)

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:list, limit}, _from, state) do
    {:reply, Enum.take(state.sessions, normalize_limit(limit)), state}
  end

  def handle_call({:get, session_id}, _from, state) do
    {:reply, find_session(state.sessions, session_id), state}
  end

  def handle_call({:start_session, attrs}, _from, state) do
    title = attrs |> Map.get("title", Map.get(attrs, :title, "")) |> normalize_text()
    body = attrs |> Map.get("body", Map.get(attrs, :body, "")) |> normalize_text()
    kind = attrs |> Map.get("kind", Map.get(attrs, :kind, "feature")) |> normalize_kind()

    cond do
      title == "" ->
        {:reply, {:error, :missing_title}, state}

      body == "" ->
        {:reply, {:error, :missing_body}, state}

      true ->
        now = now()

        session = %{
          id: state.next_id,
          kind: kind,
          title: title,
          original_request: body,
          status: "scanning",
          messages: [
            message("user", body, now),
            message("assistant", "I am scanning the configured repository and will turn this into a task draft with focused follow-up questions.", now)
          ],
          scan: nil,
          draft: "",
          created_issue: nil,
          created_at: now,
          updated_at: now
        }

        {task_ref, scan_status} = start_scan_task(session.id)
        session = %{session | status: scan_status}

        state = %{
          state
          | sessions: [session | state.sessions] |> Enum.take(@max_sessions),
            next_id: state.next_id + 1,
            scans: maybe_put_scan_task(state.scans, task_ref, session.id)
        }

        ObservabilityPubSub.broadcast_update()
        {:reply, {:ok, session}, state}
    end
  end

  def handle_call({:append_message, session_id, body}, _from, state) do
    body = normalize_text(body)

    cond do
      is_nil(session_id) ->
        {:reply, {:error, :missing_session}, state}

      body == "" ->
        {:reply, {:error, :missing_body}, state}

      true ->
        case update_session(state.sessions, session_id, &append_user_note(&1, body)) do
          {:ok, sessions, session} ->
            ObservabilityPubSub.broadcast_update()
            {:reply, {:ok, session}, %{state | sessions: sessions}}

          :error ->
            {:reply, {:error, :session_not_found}, state}
        end
    end
  end

  def handle_call({:create_linear_issue, session_id}, _from, state) do
    with session when is_map(session) <- find_session(state.sessions, session_id),
         {:ok, issue} <- create_issue_from_session(session) do
      updated_session =
        session
        |> Map.put(:status, "created")
        |> Map.put(:created_issue, issue)
        |> Map.put(:updated_at, now())
        |> Map.put(:messages, trim_messages([message("assistant", "Created Linear issue #{issue.identifier}.", now()) | session.messages]))

      sessions =
        Enum.map(state.sessions, fn
          %{id: ^session_id} -> updated_session
          other -> other
        end)

      ObservabilityPubSub.broadcast_update()
      {:reply, {:ok, updated_session}, %{state | sessions: sessions}}
    else
      nil ->
        {:reply, {:error, :session_not_found}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.scans, ref) do
      {nil, scans} ->
        {:noreply, %{state | scans: scans}}

      {session_id, scans} ->
        sessions = apply_scan_result(state.sessions, session_id, result)
        ObservabilityPubSub.broadcast_update()
        {:noreply, %{state | sessions: sessions, scans: scans}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    {:noreply, %{state | scans: Map.delete(state.scans, ref)}}
  end

  defp call_or_default(request, default) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, request, 30_000)
    else
      default
    end
  end

  defp start_scan_task(_session_id) do
    if Process.whereis(SymphonyElixir.TaskSupervisor) do
      task =
        Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
          settings = Config.settings!()
          repo_url = System.get_env("SYMPHONY_SOURCE_REPO_URL") || ""
          branch = System.get_env("SYMPHONY_SOURCE_REPO_BRANCH") || settings.tracker.project_slug || "main"
          scan_repository(repo_url, branch)
        end)

      {task.ref, "scanning"}
    else
      {nil, "scan unavailable"}
    end
  rescue
    _error ->
      {nil, "scan unavailable"}
  end

  defp maybe_put_scan_task(scans, nil, _session_id), do: scans
  defp maybe_put_scan_task(scans, ref, session_id), do: Map.put(scans, ref, session_id)

  defp apply_scan_result(sessions, session_id, {:ok, scan}) do
    Enum.map(sessions, fn
      %{id: ^session_id} = session ->
        session =
          session
          |> Map.put(:scan, scan)
          |> Map.put(:status, "drafting")
          |> Map.put(:messages, trim_messages([message("assistant", followup_questions(scan), now()) | session.messages]))
          |> Map.put(:updated_at, now())

        %{session | draft: build_draft(session)}

      other ->
        other
    end)
  end

  defp apply_scan_result(sessions, session_id, {:error, reason}) do
    Enum.map(sessions, fn
      %{id: ^session_id} = session ->
        session =
          session
          |> Map.put(:status, "needs details")
          |> Map.put(:messages, trim_messages([message("assistant", scan_failed_message(reason), now()) | session.messages]))
          |> Map.put(:updated_at, now())

        %{session | draft: build_draft(session)}

      other ->
        other
    end)
  end

  defp append_user_note(session, body) do
    now = now()
    session = %{session | messages: trim_messages([message("user", body, now) | session.messages]), updated_at: now, status: "drafting"}
    assistant_note = message("assistant", "I added that to the draft. Review the updated task, then add more detail or create the Linear issue.", now)
    session = %{session | messages: trim_messages([assistant_note | session.messages])}
    %{session | draft: build_draft(session)}
  end

  defp create_issue_from_session(session) do
    settings = Config.settings!()
    project_slug = settings.tracker.project_slug

    with {:ok, project} <- lookup_project(project_slug),
         {:ok, team} <- choose_team(project),
         state_id <- choose_state_id(team, settings.tracker.active_states),
         {:ok, response} <-
           client_module().graphql(@create_issue_mutation, %{
             teamId: team["id"],
             projectId: project["id"],
             title: session.title,
             description: session.draft || build_draft(session),
             stateId: state_id
           }),
         true <- get_in(response, ["data", "issueCreate", "success"]) == true,
         issue when is_map(issue) <- get_in(response, ["data", "issueCreate", "issue"]) do
      {:ok,
       %{
         id: issue["id"],
         identifier: issue["identifier"],
         title: issue["title"],
         url: issue["url"],
         state: get_in(issue, ["state", "name"])
       }}
    else
      false -> {:error, :issue_create_failed}
      nil -> {:error, :issue_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_create_failed}
    end
  end

  defp lookup_project(project_slug) when is_binary(project_slug) and project_slug != "" do
    with {:ok, response} <- client_module().graphql(@project_lookup_query, %{projectSlug: project_slug}),
         project when is_map(project) <- get_in(response, ["data", "projects", "nodes", Access.at(0)]) do
      {:ok, project}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :project_not_found}
    end
  end

  defp lookup_project(_project_slug), do: {:error, :missing_linear_project_slug}

  defp choose_team(%{"teams" => %{"nodes" => [team | _]}}) when is_map(team), do: {:ok, team}
  defp choose_team(_project), do: {:error, :team_not_found}

  defp choose_state_id(team, active_states) do
    state_names = Enum.map(active_states || [], &to_string/1)
    states = get_in(team, ["states", "nodes"]) || []

    case Enum.find(states, &(Map.get(&1, "name") in state_names)) do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp scan_repository("", _branch), do: {:error, :missing_repo_url}

  defp scan_repository(repo_url, branch) when is_binary(repo_url) do
    root = Path.join(System.tmp_dir!(), "symphony-intake-#{System.unique_integer([:positive])}")
    branch_args = if is_binary(branch) and branch != "", do: ["--branch", branch], else: []

    try do
      case System.cmd("git", ["clone", "--depth", "1"] ++ branch_args ++ [repo_url, root], stderr_to_stdout: true) do
        {_output, 0} -> {:ok, summarize_repo(root, repo_url, branch)}
        {output, _status} -> {:error, {:git_clone_failed, String.slice(output, 0, 500)}}
      end
    rescue
      error -> {:error, {:repo_scan_failed, Exception.message(error)}}
    after
      File.rm_rf(root)
    end
  end

  defp summarize_repo(root, repo_url, branch) do
    paths =
      root
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&String.starts_with?(&1, ".git/"))
      |> Enum.sort()

    top_level =
      root
      |> File.ls!()
      |> Enum.reject(&(&1 == ".git"))
      |> Enum.sort()

    %{
      repo_url: repo_url,
      branch: branch,
      file_count: length(paths),
      top_level: Enum.take(top_level, 30),
      languages: language_summary(paths),
      important_files: important_files(paths),
      test_hints: test_hints(paths),
      sample_paths: Enum.take(paths, 50)
    }
  end

  defp language_summary(paths) do
    paths
    |> Enum.map(&Path.extname/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_ext, count} -> -count end)
    |> Enum.take(8)
    |> Enum.map(fn {ext, count} -> "#{ext}: #{count}" end)
  end

  defp important_files(paths) do
    important_names = ~w(README.md package.json pnpm-lock.yaml yarn.lock package-lock.json mix.exs pyproject.toml requirements.txt Cargo.toml go.mod CMakeLists.txt docker-compose.yml Dockerfile)

    Enum.filter(paths, fn path ->
      Path.basename(path) in important_names or String.contains?(path, ["/test/", "/tests/", "/spec/"])
    end)
    |> Enum.take(30)
  end

  defp test_hints(paths) do
    []
    |> maybe_add_hint(Enum.any?(paths, &(&1 == "mix.exs")), "mix test")
    |> maybe_add_hint(Enum.any?(paths, &(&1 == "package.json")), "npm test or project package scripts")
    |> maybe_add_hint(Enum.any?(paths, &(&1 == "pyproject.toml" or &1 == "pytest.ini")), "pytest")
    |> maybe_add_hint(Enum.any?(paths, &(&1 == "go.mod")), "go test ./...")
    |> maybe_add_hint(Enum.any?(paths, &(&1 == "Cargo.toml")), "cargo test")
    |> Enum.reverse()
  end

  defp maybe_add_hint(hints, true, hint), do: [hint | hints]
  defp maybe_add_hint(hints, _condition, _hint), do: hints

  defp followup_questions(scan) do
    """
    Repository scan is ready.

    I need these details before creating the task:
    1. Who is the user or role affected by this change?
    2. What exact workflow should pass when this is done?
    3. What acceptance criteria and edge cases should be documented?
    4. Should this touch UI, API, data model, background jobs, tests, docs, or deployment?
    5. Are production data, sensitive data, or destructive actions off limits?

    Scan summary: #{scan.file_count} files; languages #{Enum.join(scan.languages, ", ")}; likely checks #{Enum.join(scan.test_hints, ", ")}.
    """
    |> String.trim()
  end

  defp scan_failed_message(reason) do
    "Repository scan failed or was unavailable: #{inspect(reason)}. Add the affected paths, expected behavior, and validation commands manually before creating the issue."
  end

  defp build_draft(session) do
    scan = session.scan || %{}
    user_notes = session.messages |> Enum.reverse() |> Enum.filter(&(&1.role == "user")) |> Enum.map(&"- #{&1.body}") |> Enum.join("\n")

    """
    #{session.title}

    Type: #{session.kind}

    User request:
    #{session.original_request}

    Repository scan:
    - Repo: #{Map.get(scan, :repo_url, "n/a")}
    - Branch: #{Map.get(scan, :branch, "n/a")}
    - Files scanned: #{Map.get(scan, :file_count, "n/a")}
    - Top level: #{join_list(Map.get(scan, :top_level, []))}
    - Languages: #{join_list(Map.get(scan, :languages, []))}
    - Important files: #{join_list(Map.get(scan, :important_files, []))}
    - Likely validation: #{join_list(Map.get(scan, :test_hints, []))}

    Discussion notes:
    #{if user_notes == "", do: "- n/a", else: user_notes}

    Proposed plan:
    1. Reproduce or inspect the current behavior from the affected user workflow.
    2. Inventory affected routes, roles, inputs, buttons, modals, states, APIs, data paths, and tests.
    3. Define acceptance criteria and finite risk-based edge cases in the workpad before implementation.
    4. Implement the smallest coherent fix or feature slice.
    5. Run focused regression tests and visible UI/demo validation where relevant.
    6. Record evidence and hand off to the separate reviewer phase.

    Acceptance criteria to confirm:
    - Main user workflow is specified and passes.
    - Edge cases are finite and documented.
    - Regression tests cover affected contracts.
    - Visible/demo evidence is recorded for UI, browser, or desktop work.

    Safety:
    - Ask before production access, sensitive data access, or destructive actions.
    """
    |> String.trim()
  end

  defp join_list([]), do: "n/a"
  defp join_list(values) when is_list(values), do: Enum.join(values, ", ")

  defp message(role, body, created_at), do: %{role: role, body: body, created_at: created_at}

  defp update_session(sessions, session_id, fun) do
    case Enum.split_with(sessions, &(&1.id == session_id)) do
      {[session], rest} ->
        updated = fun.(session)
        {:ok, [updated | rest] |> Enum.sort_by(&DateTime.to_unix(&1.updated_at, :microsecond), :desc), updated}

      _ ->
        :error
    end
  end

  defp find_session(sessions, session_id), do: Enum.find(sessions, &(&1.id == session_id))

  defp trim_messages(messages), do: Enum.take(messages, @max_messages)
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_sessions)
  defp normalize_limit(_limit), do: @max_sessions
  defp normalize_id(value) when is_integer(value) and value > 0, do: value

  defp normalize_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp normalize_id(_value), do: nil
  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value), do: to_string(value || "") |> String.trim()
  defp normalize_kind("fix"), do: "fix"
  defp normalize_kind("feature"), do: "feature"
  defp normalize_kind("chore"), do: "chore"
  defp normalize_kind(_kind), do: "feature"
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp client_module, do: Application.get_env(:symphony_elixir, :linear_client_module, Client)
end
