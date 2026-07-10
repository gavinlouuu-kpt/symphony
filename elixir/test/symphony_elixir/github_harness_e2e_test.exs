defmodule SymphonyElixir.GithubHarnessE2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Workflow

  @moduletag timeout: 30_000

  defmodule FakeGithubClient do
    def fetch_candidate_issues do
      notify(:github_harness_fetch_candidate_issues)
      {:ok, issues()}
    end

    def fetch_issues_by_states(states) do
      notify({:github_harness_fetch_issues_by_states, states})

      filtered =
        issues()
        |> Enum.filter(&(&1.state in states))

      {:ok, filtered}
    end

    def fetch_issue_states_by_ids(ids) do
      notify({:github_harness_fetch_issue_states_by_ids, ids})
      ids = MapSet.new(ids)

      filtered =
        issues()
        |> Enum.filter(&MapSet.member?(ids, &1.id))

      {:ok, filtered}
    end

    def create_comment(issue_id, body) do
      notify({:github_harness_create_comment, issue_id, body})
      :ok
    end

    def update_issue_state(issue_id, state_id) do
      notify({:github_harness_update_issue_state, issue_id, state_id})
      :ok
    end

    defp issues do
      Application.get_env(:symphony_elixir, :github_harness_e2e_issues, [])
    end

    defp notify(event) do
      if recipient = Application.get_env(:symphony_elixir, :github_harness_e2e_recipient) do
        send(recipient, event)
      end
    end
  end

  test "GitHub issue orchestration carries Planner -> Generator -> Evaluator harness evidence" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-github-harness-e2e-#{System.unique_integer([:positive])}")

    trace_file = Path.join(test_root, "codex.trace")
    fake_codex = Path.join(test_root, "fake-codex")
    workspace_root = Path.join(test_root, "workspaces")
    issue_id = "github:gavinlouuu-kpt/template-agent-harness#94"

    issue = %Issue{
      id: issue_id,
      identifier: "GH-94",
      title: "Multi prompt interactive annotation for SAM2 backend",
      description: "Create a looped planning/generation/evaluation workflow for a SAM2 annotation backend.",
      state: "open",
      url: "https://github.com/gavinlouuu-kpt/template-agent-harness/issues/94",
      labels: ["symphony-harness-e2e"],
      assigned_to_worker: true
    }

    previous_github_client = Application.get_env(:symphony_elixir, :github_client_module)
    previous_issues = Application.get_env(:symphony_elixir, :github_harness_e2e_issues)
    previous_recipient = Application.get_env(:symphony_elixir, :github_harness_e2e_recipient)

    on_exit(fn ->
      restore_app_env(:github_client_module, previous_github_client)
      restore_app_env(:github_harness_e2e_issues, previous_issues)
      restore_app_env(:github_harness_e2e_recipient, previous_recipient)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    File.write!(fake_codex, fake_codex_app_server(trace_file))
    File.chmod!(fake_codex, 0o755)

    Application.put_env(:symphony_elixir, :github_client_module, FakeGithubClient)
    Application.put_env(:symphony_elixir, :github_harness_e2e_issues, [issue])
    Application.put_env(:symphony_elixir, :github_harness_e2e_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com",
      tracker_api_token: "github-token",
      tracker_project_slug: "gavinlouuu-kpt/template-agent-harness",
      tracker_required_labels: ["symphony-harness-e2e"],
      tracker_active_states: ["open"],
      tracker_terminal_states: ["closed"],
      workspace_root: workspace_root,
      poll_interval_ms: 20,
      max_concurrent_agents: 1,
      max_turns: 1,
      max_retry_backoff_ms: 300_000,
      codex_command: "#{fake_codex} app-server",
      codex_turn_timeout_ms: 5_000,
      codex_stall_timeout_ms: 5_000,
      prompt: project_template_prompt!()
    )

    orchestrator_name = Module.concat(__MODULE__, HarnessOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    try do
      assert_eventually(
        fn ->
          trace_file
          |> File.read()
          |> case do
            {:ok, trace} -> String.contains?(trace, "HARNESS_E2E_PASS GH-94")
            {:error, _} -> false
          end
        end,
        fn ->
          case File.read(trace_file) do
            {:ok, trace} -> "fake codex trace:\n#{trace}"
            {:error, reason} -> "fake codex trace was not created: #{inspect(reason)}"
          end
        end
      )

      Application.put_env(:symphony_elixir, :github_harness_e2e_issues, [
        %{issue | state: "closed"}
      ])

      assert_received :github_harness_fetch_candidate_issues
      assert_received {:github_harness_fetch_issue_states_by_ids, [^issue_id]}

      trace = File.read!(trace_file)
      turn_prompt = turn_prompt!(trace)

      assert File.dir?(Path.join(workspace_root, "GH-94"))
      assert trace =~ "PROMPT_CONTRACT_OK"
      assert trace =~ "PHASE:PLANNER"
      assert trace =~ "PHASE:GENERATOR"
      assert trace =~ "PHASE:EVALUATOR"
      assert trace =~ "HARNESS_E2E_PASS GH-94"

      assert turn_prompt =~ "GH-94"
      assert turn_prompt =~ "https://github.com/gavinlouuu-kpt/template-agent-harness/issues/94"
      assert turn_prompt =~ "Multi prompt interactive annotation for SAM2 backend"
      assert turn_prompt =~ "`agent.role_agents`"
      assert turn_prompt =~ "separate Planner,\nGenerator, and Evaluator app-server sessions"
      assert turn_prompt =~ "A single agent writing three\nsections"
      assert turn_prompt =~ "independent Planner -> Generator -> Evaluator cycle"
      assert turn_prompt =~ "/review"

      assert count_json_rpc_method(trace, "thread/start") == 1
      assert count_json_rpc_method(trace, "turn/start") == 1
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp project_template_prompt! do
    template =
      __DIR__
      |> Path.join("../../ops/project-template/WORKFLOW.md.template")
      |> Path.expand()
      |> File.read!()

    [_, _, prompt] = String.split(template, "---", parts: 3)
    String.trim_leading(prompt)
  end

  defp fake_codex_app_server(trace_file) do
    """
    #!/bin/sh
    trace_file="#{trace_file}"
    : > "$trace_file"

    emit() {
      printf '%s\\n' "$1"
      printf 'OUT:%s\\n' "$1" >> "$trace_file"
    }

    require_text() {
      needle="$1"
      label="$2"

      case "$line" in
        *"$needle"*) printf 'CHECK:%s:ok\\n' "$label" >> "$trace_file" ;;
        *) printf 'CHECK:%s:missing\\n' "$label" >> "$trace_file"; missing=1 ;;
      esac
    }

    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"thread/start"'*)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-harness-e2e"}}}'
          ;;
        *'"method":"turn/start"'*)
          missing=0
          require_text "GH-94" "issue-identifier"
          require_text "github.com/gavinlouuu-kpt/template-agent-harness/issues/94" "issue-url"
          require_text "Multi prompt interactive annotation for SAM2 backend" "issue-title"
          require_text "agent.role_agents" "role-agent-config"
          require_text "separate Planner," "independent-planner"
          require_text "Generator, and Evaluator app-server sessions" "independent-sessions"
          require_text "single agent writing three" "no-single-agent"
          require_text "independent Planner -> Generator -> Evaluator cycle" "role-agent-cycle"
          require_text "/review" "review-mode-distinction"

          if [ "$missing" -ne 0 ]; then
            printf '%s\\n' '{"id":3,"error":{"code":-32000,"message":"missing harness contract"}}'
            exit 1
          fi

          printf 'PROMPT_CONTRACT_OK\\n' >> "$trace_file"
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-harness-e2e"}}}'
          emit '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"PHASE:PLANNER accepted GH-94 issue context and bounded plan","phase":"commentary"}}}'
          emit '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"PHASE:GENERATOR produced the requested implementation path","phase":"commentary"}}}'
          emit '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"PHASE:EVALUATOR PASS verified phase evidence","phase":"commentary"}}}'
          emit '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"HARNESS_E2E_PASS GH-94","phase":"final_answer"}}}'
          emit '{"method":"turn/completed","params":{"turn":{"status":"completed"},"usage":{"input_tokens":10,"output_tokens":4,"total_tokens":14}}}'
          exit 0
          ;;
        *)
          ;;
      esac
    done
    """
  end

  defp turn_prompt!(trace) do
    trace
    |> json_rpc_messages()
    |> Enum.find_value(fn
      %{"method" => "turn/start", "params" => %{"input" => input}} ->
        input
        |> Enum.map(&Map.fetch!(&1, "text"))
        |> Enum.join("\n")

      _ ->
        nil
    end)
    |> case do
      nil -> flunk("expected a turn/start JSON-RPC message in #{trace}")
      prompt -> prompt
    end
  end

  defp count_json_rpc_method(trace, method) do
    trace
    |> json_rpc_messages()
    |> Enum.count(&match?(%{"method" => ^method}, &1))
  end

  defp json_rpc_messages(trace) do
    trace
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "JSON:"))
    |> Enum.map(fn "JSON:" <> json -> Jason.decode!(json) end)
  end

  defp assert_eventually(fun, on_timeout, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, on_timeout, deadline)
  end

  defp do_assert_eventually(fun, on_timeout, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met before timeout\n#{on_timeout.()}")
      else
        Process.sleep(25)
        do_assert_eventually(fun, on_timeout, deadline)
      end
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
