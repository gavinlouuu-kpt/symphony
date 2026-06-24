defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Cua.Sandbox
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    runtime = worker_runtime!(issue, opts)
    worker_host = Map.get(runtime, :worker_host)
    sandbox = Map.get(runtime, :sandbox)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} sandbox=#{sandbox_name_for_log(sandbox)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host, sandbox) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp worker_runtime!(issue, opts) do
    settings = Config.settings!()

    case settings.worker.provider do
      "cua" ->
        case Sandbox.ensure_for_issue(issue) do
          {:ok, runtime} -> runtime
          {:error, reason} -> raise RuntimeError, "CUA sandbox provisioning failed for #{issue_context(issue)}: #{inspect(reason)}"
        end

      _ ->
        %{
          worker_host: selected_worker_host(Keyword.get(opts, :worker_host), settings.worker.ssh_hosts),
          sandbox: nil
        }
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host, sandbox) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} sandbox=#{sandbox_name_for_log(sandbox)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace, sandbox)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, sandbox)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace, sandbox)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace,
         sandbox: sandbox
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace, _sandbox), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, sandbox) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    codex_context = codex_context!(issue, workspace, worker_host, sandbox)

    try do
      with {:ok, session} <- AppServer.start_session(codex_context.workspace, codex_context.start_opts) do
        try do
          do_run_codex_turns(
            session,
            workspace,
            issue,
            codex_update_recipient,
            Keyword.put(opts, :prompt_prefix, codex_context.prompt_prefix),
            issue_state_fetcher,
            1,
            max_turns
          )
        after
          AppServer.stop_session(session)
        end
      end
    after
      codex_context.cleanup.()
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    prompt_prefix = Keyword.get(opts, :prompt_prefix, "")
    prompt_prefix <> PromptBuilder.build_prompt(issue, opts)
  end

  defp build_turn_prompt(_issue, opts, turn_number, max_turns) do
    prompt_prefix = Keyword.get(opts, :prompt_prefix, "")

    prompt_prefix <>
      """
      Continuation guidance:

      - The previous Codex turn completed normally, but the Linear issue is still in an active state.
      - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
      - Resume from the current workspace and workpad state instead of restarting from scratch.
      - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
      - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
      """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp sandbox_name_for_log(%{name: name}) when is_binary(name), do: name
  defp sandbox_name_for_log(_sandbox), do: "none"

  defp codex_context!(issue, workspace, worker_host, %{provider: "cua"} = sandbox)
       when is_binary(workspace) and is_binary(worker_host) do
    root = Path.join(System.tmp_dir!(), "symphony_cua_agent_workspaces")
    host_workspace = Path.join(root, safe_identifier(issue_identifier(issue)))

    File.rm_rf!(host_workspace)
    File.mkdir_p!(host_workspace)

    %{
      workspace: host_workspace,
      start_opts: [
        workspace_root: root,
        dynamic_tool_context: %{
          sandbox: %{
            provider: "cua",
            name: Map.get(sandbox, :name),
            worker_host: worker_host,
            workspace: workspace
          }
        }
      ],
      prompt_prefix: cua_host_agent_prompt(workspace),
      cleanup: fn -> File.rm_rf(host_workspace) end
    }
  end

  defp codex_context!(_issue, workspace, worker_host, _sandbox) do
    %{
      workspace: workspace,
      start_opts: [worker_host: worker_host],
      prompt_prefix: "",
      cleanup: fn -> :ok end
    }
  end

  defp cua_host_agent_prompt(workspace) do
    """
    Symphony is running you on the host orchestrator while the issue's actual development environment is a CUA sandbox.

    The CUA sandbox workspace is:
    #{workspace}

    Your local working directory is only a host-side control workspace. Do not use local shell commands or local file edits for issue work.
    When task instructions refer to the current working directory or workspace root, interpret that as the CUA sandbox workspace above.
    Use `sandbox_exec` for shell commands in the CUA workspace, `sandbox_read_file` to inspect sandbox files, and `sandbox_write_file` to write sandbox files.
    Use `linear_graphql` for Linear API work.

    """
  end

  defp issue_identifier(%Issue{identifier: identifier, id: id}), do: identifier || id
  defp issue_identifier(%{identifier: identifier}), do: identifier
  defp issue_identifier(%{"identifier" => identifier}), do: identifier
  defp issue_identifier(%{id: id}), do: id
  defp issue_identifier(%{"id" => id}), do: id
  defp issue_identifier(_issue), do: "issue"

  defp safe_identifier(identifier) do
    identifier
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
