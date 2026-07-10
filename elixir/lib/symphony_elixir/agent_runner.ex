defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Cua.Sandbox
  alias SymphonyElixir.OpenClaw.Notifier, as: OpenClawNotifier
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil
  @max_supervision_retries 2

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
    settings = Config.settings!()
    max_turns = Keyword.get(opts, :max_turns, settings.agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    codex_context = codex_context!(issue, workspace, worker_host, sandbox)
    role_agents = settings.agent.role_agents

    try do
      if role_agents == [] do
        run_single_agent_turns(
          codex_context,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          max_turns
        )
      else
        do_run_role_agent_cycles(
          codex_context,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          role_agents,
          1,
          max_turns
        )
      end
    after
      codex_context.cleanup.()
    end
  end

  defp run_single_agent_turns(
         codex_context,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         max_turns
       ) do
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
          max_turns,
          supervision_context(codex_context, workspace)
        )
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns,
         supervision_context
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session, supervision_signals} <-
           run_supervised_turn(app_session, prompt, issue, codex_update_recipient, supervision_context) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      cond do
        supervision_signals != [] and turn_number < max_turns ->
          Logger.warning("Supervising CUA sandbox worker for #{issue_context(issue)} after host control workspace misuse: #{summarize_supervision_signals(supervision_signals)}")

          do_run_codex_turns(
            app_session,
            workspace,
            issue,
            codex_update_recipient,
            opts
            |> Keyword.put(:prompt_override, cua_supervision_prompt(workspace, nil, supervision_signals)),
            issue_state_fetcher,
            turn_number + 1,
            max_turns,
            supervision_context
          )

        supervision_signals != [] ->
          {:error, {:cua_supervision_unresolved, summarize_supervision_signals(supervision_signals)}}

        true ->
          case continue_with_issue?(issue, issue_state_fetcher) do
            {:continue, refreshed_issue} when turn_number < max_turns ->
              Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

              do_run_codex_turns(
                app_session,
                workspace,
                refreshed_issue,
                codex_update_recipient,
                Keyword.delete(opts, :prompt_override),
                issue_state_fetcher,
                turn_number + 1,
                max_turns,
                supervision_context
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
  end

  defp do_run_role_agent_cycles(
         codex_context,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         role_agents,
         cycle_number,
         max_cycles
       ) do
    case run_role_agent_sequence(
           codex_context,
           workspace,
           issue,
           codex_update_recipient,
           opts,
           issue_state_fetcher,
           role_agents,
           cycle_number,
           max_cycles
         ) do
      {:continue, refreshed_issue} when cycle_number < max_cycles ->
        Logger.info("Continuing independent role-agent cycle for #{issue_context(refreshed_issue)} cycle=#{cycle_number}/#{max_cycles}")

        do_run_role_agent_cycles(
          codex_context,
          workspace,
          refreshed_issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          role_agents,
          cycle_number + 1,
          max_cycles
        )

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active after independent role-agent cycles")
        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_role_agent_sequence(
         codex_context,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         role_agents,
         cycle_number,
         max_cycles
       ) do
    role_agents
    |> Enum.with_index(1)
    |> Enum.reduce_while({:continue, issue}, fn {role, role_index}, {_status, current_issue} ->
      case run_independent_role_agent(
             codex_context,
             workspace,
             current_issue,
             codex_update_recipient,
             opts,
             role,
             role_index,
             role_agents,
             cycle_number,
             max_cycles
           ) do
        :ok ->
          case continue_with_issue?(current_issue, issue_state_fetcher) do
            {:continue, refreshed_issue} -> {:cont, {:continue, refreshed_issue}}
            {:done, refreshed_issue} -> {:halt, {:done, refreshed_issue}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp run_independent_role_agent(
         codex_context,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         role,
         role_index,
         role_agents,
         cycle_number,
         max_cycles
       ) do
    prompt =
      build_role_agent_prompt(
        issue,
        Keyword.put(opts, :prompt_prefix, codex_context.prompt_prefix),
        role,
        role_index,
        role_agents,
        cycle_number,
        max_cycles
      )

    Logger.info("Starting independent role agent #{role} for #{issue_context(issue)} workspace=#{workspace} cycle=#{cycle_number}/#{max_cycles}")

    with {:ok, session} <- AppServer.start_session(codex_context.workspace, codex_context.start_opts) do
      try do
        run_role_agent_turn_with_supervision(
          session,
          prompt,
          workspace,
          issue,
          codex_update_recipient,
          role,
          cycle_number,
          max_cycles,
          supervision_context(codex_context, workspace),
          0
        )
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp run_role_agent_turn_with_supervision(
         session,
         prompt,
         workspace,
         issue,
         codex_update_recipient,
         role,
         cycle_number,
         max_cycles,
         supervision_context,
         supervision_attempt
       ) do
    with {:ok, turn_session, supervision_signals} <-
           run_supervised_turn(session, prompt, issue, codex_update_recipient, supervision_context) do
      Logger.info("Completed independent role agent #{role} for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} cycle=#{cycle_number}/#{max_cycles}")

      cond do
        supervision_signals != [] and supervision_attempt < @max_supervision_retries ->
          Logger.warning("Supervising independent role agent #{role} for #{issue_context(issue)} after host control workspace misuse: #{summarize_supervision_signals(supervision_signals)}")

          run_role_agent_turn_with_supervision(
            session,
            cua_supervision_prompt(workspace, role, supervision_signals),
            workspace,
            issue,
            codex_update_recipient,
            role,
            cycle_number,
            max_cycles,
            supervision_context,
            supervision_attempt + 1
          )

        supervision_signals != [] ->
          {:error, {:cua_supervision_unresolved, summarize_supervision_signals(supervision_signals)}}

        true ->
          publish_role_agent_completed(issue, role, cycle_number, max_cycles, turn_session, workspace)
          :ok
      end
    end
  end

  defp publish_role_agent_completed(issue, role, cycle_number, max_cycles, turn_session, workspace) do
    OpenClawNotifier.publish(:role_agent_completed, %{
      issue: issue,
      issue_id: issue.id,
      identifier: issue.identifier,
      role: role,
      cycle: cycle_number,
      max_cycles: max_cycles,
      session_id: turn_session[:session_id],
      workspace_path: workspace
    })
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    case Keyword.get(opts, :prompt_override) do
      prompt when is_binary(prompt) -> prompt
      _ -> Keyword.get(opts, :prompt_prefix, "") <> PromptBuilder.build_prompt(issue, opts)
    end
  end

  defp build_turn_prompt(_issue, opts, turn_number, max_turns) do
    case Keyword.get(opts, :prompt_override) do
      prompt when is_binary(prompt) ->
        prompt

      _ ->
        Keyword.get(opts, :prompt_prefix, "") <>
          """
          Continuation guidance:

          - The previous Codex turn completed normally, but the tracker issue is still in an active state.
          - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
          - Resume from the current workspace and workpad state instead of restarting from scratch.
          - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
          - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
          """
    end
  end

  defp build_role_agent_prompt(issue, opts, role, role_index, role_agents, cycle_number, max_cycles) do
    prompt_prefix = Keyword.get(opts, :prompt_prefix, "")

    prompt_prefix <>
      role_agent_instructions(role, role_index, role_agents, cycle_number, max_cycles) <>
      "\n\n" <>
      PromptBuilder.build_prompt(issue, opts)
  end

  defp role_agent_instructions(role, role_index, role_agents, cycle_number, max_cycles) do
    normalized_role = role |> to_string() |> String.trim() |> String.downcase()
    all_roles = Enum.map_join(role_agents, " -> ", &to_string/1)

    base = """
    Independent Symphony role agent:

    - Role: #{role}
    - Role order: #{role_index}/#{length(role_agents)} in #{all_roles}
    - Role-agent cycle: #{cycle_number}/#{max_cycles}
    - This is a fresh independent agent session. Do not assume chat context from other role agents.
    - Coordinate only through repository state, tracker comments, PRs, logs, and the `## Codex Workpad`.
    - Use bounded autonomy to unblock routine workflow gaps: inspect the tracker, repo, logs, and existing docs; retry transient failures; choose conservative assumptions; and record those assumptions in the workpad.
    - Stop for Gavin only when the blocker requires secrets/credentials, destructive or irreversible operations, paid external resource changes, licensing/legal approval, unavailable required hardware/data, or a product decision where a wrong assumption would materially change the feature.
    - Update `### Phase Evidence` in the workpad for this exact role before exiting.
    - Do not collapse Planner, Generator, and Evaluator into a single self-review.
    - You may spawn bounded Codex subagents for independent read-heavy exploration, log analysis, test-gap review, or focused evaluator checks. Wait for them, summarize their conclusions in your role evidence, and do not treat their summaries as a replacement for this role's own verdict.
    - Keep write ownership serialized: subagents must not edit project files, push branches, change tracker labels, close issues, or mark handoff complete unless the project workflow explicitly grants that authority. Prefer subagents for investigation and review, not parallel code edits.
    """

    base <> "\n" <> role_specific_instructions(normalized_role)
  end

  defp role_specific_instructions("planner") do
    """
    Planner responsibilities:

    - Do not make product code edits, push branches, create PRs, remove active routing labels, close issues, or mark work ready.
    - Read the current project `AGENTS.md` and required discovery docs before planning.
    - For Large or cross-boundary issues, use read-only subagents to inspect separable surfaces such as docs, UI, backend, infra, tests, or logs, then merge their findings into one concrete plan.
    - Clarify scope, tier, assumptions, acceptance criteria, risks, and validation.
    - If the issue is materially ambiguous after repository/tracker inspection, update the workpad with exact questions/blockers instead of implementing.
    - Leave a concrete implementation plan for the Generator agent.
    """
  end

  defp role_specific_instructions("generator") do
    """
    Generator responsibilities:

    - Read the Planner evidence first and implement only against the accepted plan.
    - Use subagents only for bounded investigation, validation triage, or test/log analysis while you retain responsibility for the implementation diff.
    - Keep changes scoped, update required docs, and run focused validation.
    - Fix ordinary local setup, dependency, formatting, and test failures that are within issue scope instead of stopping at the first error.
    - Push/update the branch and PR when code is ready, but do not remove active routing labels, close the issue, or claim final review.
    - Record changed files, validation commands, and implementation notes for the Evaluator agent.
    """
  end

  defp role_specific_instructions("evaluator") do
    """
    Evaluator responsibilities:

    - Independently review the issue, Planner evidence, Generator changes, diff, tests, docs, PR/check status, and project guardrails.
    - For Medium/Large work, use focused review subagents for independent angles such as correctness, tests, docs, security, UI/runtime smoke, or operational risk, then reconcile their findings into one evaluator verdict.
    - Do not implement new feature work. Only make minimal tracker/workpad updates unless the workflow explicitly allows small review fixes.
    - If the work fails, record concrete rework findings, distinguish fixable rework from hard blockers, and leave the issue routed for another cycle.
    - If the work passes, complete the workflow handoff exactly as the project workflow requires.
    - `/review` alone is not an independent evaluator agent and does not satisfy this role.
    """
  end

  defp role_specific_instructions(_role) do
    """
    Role responsibilities:

    - Execute only this named role's responsibility.
    - Coordinate through durable tracker/workpad evidence.
    - Stop after this role's evidence is complete.
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

  defp run_supervised_turn(app_session, prompt, issue, codex_update_recipient, supervision_context) do
    {:ok, signal_store} = Agent.start_link(fn -> [] end)

    handler = fn message ->
      send_codex_update(codex_update_recipient, issue, message)
      maybe_record_supervision_signal(signal_store, message, supervision_context)
    end

    try do
      case AppServer.run_turn(app_session, prompt, issue, on_message: handler) do
        {:ok, turn_session} ->
          {:ok, turn_session, Agent.get(signal_store, &Enum.reverse/1)}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Agent.stop(signal_store)
    end
  end

  defp maybe_record_supervision_signal(_signal_store, _message, nil), do: :ok

  defp maybe_record_supervision_signal(signal_store, message, %{provider: "cua"} = context) do
    case supervision_signal_for_message(message, context) do
      nil ->
        :ok

      signal ->
        Agent.update(signal_store, fn signals ->
          if Enum.any?(signals, &(&1.type == signal.type and &1.text == signal.text)) do
            signals
          else
            [signal | signals]
          end
        end)
    end
  end

  defp supervision_signal_for_message(%{event: :stream_output} = message, context) do
    text = stream_output_text(message)

    if host_control_workspace_misuse?(text, context) do
      %{
        type: :cua_host_control_workspace_misuse,
        text: summarize_signal_text(text)
      }
    end
  end

  defp supervision_signal_for_message(_message, _context), do: nil

  defp stream_output_text(%{payload: payload}) when is_binary(payload), do: payload
  defp stream_output_text(%{raw: raw}) when is_binary(raw), do: raw
  defp stream_output_text(_message), do: ""

  defp host_control_workspace_misuse?(text, %{host_workspace: host_workspace, host_workspace_root: root})
       when is_binary(text) do
    normalized = String.downcase(text)

    mentions_host_workspace? =
      String.contains?(text, host_workspace) or String.contains?(text, root)

    file_tool_failure? =
      String.contains?(normalized, [
        "failed to write file",
        "failed to read file to update",
        "apply_patch verification failed",
        "fs sandbox helper failed",
        "bwrap:"
      ])

    mentions_host_workspace? and file_tool_failure?
  end

  defp summarize_signal_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 400)
  end

  defp summarize_supervision_signals(signals) do
    signals
    |> Enum.map(& &1.text)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(3)
    |> Enum.join(" | ")
  end

  defp supervision_context(%{workspace: host_workspace, start_opts: start_opts}, sandbox_workspace)
       when is_binary(host_workspace) and is_binary(sandbox_workspace) do
    dynamic_tool_context = Keyword.get(start_opts, :dynamic_tool_context, %{}) || %{}
    sandbox_context = Map.get(dynamic_tool_context, :sandbox) || Map.get(dynamic_tool_context, "sandbox")

    if sandbox_provider(sandbox_context) == "cua" do
      %{
        provider: "cua",
        host_workspace: Path.expand(host_workspace),
        host_workspace_root: Path.expand(Path.join(System.tmp_dir!(), "symphony_cua_agent_workspaces")),
        sandbox_workspace: sandbox_workspace
      }
    end
  end

  defp supervision_context(_codex_context, _sandbox_workspace), do: nil

  defp sandbox_provider(%{} = sandbox_context) do
    Map.get(sandbox_context, :provider) || Map.get(sandbox_context, "provider")
  end

  defp sandbox_provider(_sandbox_context), do: nil

  defp cua_supervision_prompt(workspace, role, signals) do
    role_line =
      case role do
        nil -> "- Continue the current agent run after applying this correction."
        role -> "- Continue the current `#{role}` role after applying this correction."
      end

    signal_lines =
      signals
      |> Enum.map(&"- #{&1.text}")
      |> Enum.join("\n")

    """
    Symphony supervisor correction:

    The previous turn attempted to use host-local file tools in the Codex control workspace. That workspace is not the project workspace.

    Observed signal:
    #{signal_lines}

    The actual CUA sandbox workspace is:
    #{workspace}

    Required correction:
    - Do not use local shell commands, apply_patch, or direct local file writes for project work in this session.
    - Use only `sandbox_exec`, `sandbox_visible_exec`, `sandbox_read_file`, and `sandbox_write_file` for project inspection and edits.
    - Inspect sandbox state with `sandbox_exec` and repair or retry the failed work inside the sandbox workspace.
    - Update durable tracker/workpad evidence for the current phase before exiting.
    - Do not ask the operator to unblock this; this is a routine workflow correction.
    #{role_line}
    """
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
    Use `sandbox_exec` for headless shell commands in the CUA workspace, `sandbox_visible_exec` for commands that must be visible through noVNC, `sandbox_read_file` to inspect sandbox files, `sandbox_write_file` to write sandbox files, and `symphony_record_evidence` to run required handoff validation commands that must count toward the project evidence contract.
    When the issue asks for real-user testing, noVNC/demo evidence, browser/app validation, or visible desktop activity, you must use `sandbox_visible_exec` for the relevant app/test commands and document the transcript path under `.symphony/visible-exec`.
    When the workflow config has `agent.role_agents`, Symphony starts separate independent Planner, Generator, and Evaluator app-server sessions for the issue. Do not collapse those roles into one agent turn. Do not treat /review as a delegated sub-agent; it is a mode/manual review surface and does not satisfy the Evaluator agent. Keep all project commands inside the CUA sandbox tools.
    Use tracker-specific dynamic tools only when they are relevant to the configured workflow.

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
