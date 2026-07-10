defmodule SymphonyElixir.LinearResolutionHarnessE2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Workflow

  @moduletag timeout: 30_000

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      notify(:linear_resolution_fetch_candidate_issues)

      issues =
        case current_issue() do
          %Issue{state: "Todo"} = issue -> [issue]
          _ -> []
        end

      {:ok, issues}
    end

    def fetch_issues_by_states(states) do
      notify({:linear_resolution_fetch_issues_by_states, states})
      normalized_states = MapSet.new(Enum.map(states, &normalize_state/1))

      issues =
        case current_issue() do
          %Issue{} = issue ->
            if MapSet.member?(normalized_states, normalize_state(issue.state)), do: [issue], else: []

          _ ->
            []
        end

      {:ok, issues}
    end

    def fetch_issue_states_by_ids(ids) do
      notify({:linear_resolution_fetch_issue_states_by_ids, ids})
      wanted_ids = MapSet.new(ids)

      issues =
        case current_issue() do
          %Issue{} = issue ->
            if MapSet.member?(wanted_ids, issue.id), do: [issue], else: []

          _ ->
            []
        end

      {:ok, issues}
    end

    def graphql(query, variables), do: graphql(query, variables, [])

    def graphql(query, variables, opts) do
      notify({:linear_resolution_graphql, query, variables, opts})

      cond do
        String.contains?(query, "commentCreate") ->
          issue_id = Map.fetch!(variables, "issueId")
          body = Map.fetch!(variables, "body")
          evidence_complete? = phase_evidence_complete?(body)
          Application.put_env(:symphony_elixir, :linear_resolution_e2e_phase_evidence_complete, evidence_complete?)
          notify({:linear_resolution_comment_created, issue_id, body})

          if evidence_complete? do
            {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
          else
            {:ok, %{"errors" => [%{"message" => "phase evidence incomplete"}]}}
          end

        String.contains?(query, "issueUpdate") ->
          issue_id = Map.get(variables, "issueId") || Map.fetch!(variables, "id")
          state_name = Map.get(variables, "stateId") || Map.get(variables, "stateName") || "Done"

          if Application.get_env(:symphony_elixir, :linear_resolution_e2e_phase_evidence_complete, false) do
            update_issue_state!(issue_id, state_name)
            notify({:linear_resolution_state_updated, issue_id, state_name})

            {:ok,
             %{
               "data" => %{
                 "issueUpdate" => %{
                   "success" => true,
                   "issue" => %{"id" => issue_id, "state" => %{"name" => state_name}}
                 }
               }
             }}
          else
            {:ok, %{"errors" => [%{"message" => "cannot close before phase evidence is persisted"}]}}
          end

        true ->
          {:ok, %{"data" => %{"viewer" => %{"id" => "fake-linear-viewer"}}}}
      end
    end

    defp current_issue do
      Application.get_env(:symphony_elixir, :linear_resolution_e2e_issue)
    end

    defp update_issue_state!(issue_id, state_name) do
      case current_issue() do
        %Issue{id: ^issue_id} = issue ->
          Application.put_env(:symphony_elixir, :linear_resolution_e2e_issue, %{issue | state: state_name})

        _ ->
          :ok
      end
    end

    defp phase_evidence_complete?(body) when is_binary(body) do
      body =~ "Planner: scoped the issue" and
        body =~ "Generator: implemented" and
        body =~ "Evaluator: PASS"
    end

    defp phase_evidence_complete?(_body), do: false

    defp notify(event) do
      if recipient = Application.get_env(:symphony_elixir, :linear_resolution_e2e_recipient) do
        send(recipient, event)
      end
    end

    defp normalize_state(state) when is_binary(state) do
      state
      |> String.trim()
      |> String.downcase()
    end

    defp normalize_state(_state), do: ""
  end

  test "issue resolves through Planner, Generator, and Evaluator phases before terminal state" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-linear-resolution-e2e-#{System.unique_integer([:positive])}")

    trace_file = Path.join(test_root, "codex.trace")
    fake_codex = Path.join(test_root, "fake-codex")
    workspace_root = Path.join(test_root, "workspaces")
    issue_id = "issue-linear-resolution-e2e"

    issue = %Issue{
      id: issue_id,
      identifier: "LIN-RESOLVE",
      title: "Resolve issue with all harness agents",
      description: "Run Planner, Generator, and Evaluator before resolving the issue.",
      state: "Todo",
      url: "https://linear.app/symphony/issue/LIN-RESOLVE",
      labels: ["symphony-harness-e2e"],
      assigned_to_worker: true
    }

    previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_issue = Application.get_env(:symphony_elixir, :linear_resolution_e2e_issue)
    previous_recipient = Application.get_env(:symphony_elixir, :linear_resolution_e2e_recipient)
    previous_phase_evidence = Application.get_env(:symphony_elixir, :linear_resolution_e2e_phase_evidence_complete)

    on_exit(fn ->
      restore_app_env(:linear_client_module, previous_linear_client)
      restore_app_env(:linear_resolution_e2e_issue, previous_issue)
      restore_app_env(:linear_resolution_e2e_recipient, previous_recipient)
      restore_app_env(:linear_resolution_e2e_phase_evidence_complete, previous_phase_evidence)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    File.write!(fake_codex, fake_codex_app_server(trace_file, issue_id))
    File.chmod!(fake_codex, 0o755)

    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :linear_resolution_e2e_issue, issue)
    Application.put_env(:symphony_elixir, :linear_resolution_e2e_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "https://api.linear.app/graphql",
      tracker_api_token: "linear-token",
      tracker_project_slug: "symphony",
      tracker_required_labels: ["symphony-harness-e2e"],
      tracker_active_states: ["Todo"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      poll_interval_ms: 20,
      max_concurrent_agents: 1,
      max_turns: 1,
      max_retry_backoff_ms: 300_000,
      codex_command: "#{fake_codex} app-server",
      codex_turn_timeout_ms: 5_000,
      codex_stall_timeout_ms: 5_000,
      prompt: resolution_prompt()
    )

    orchestrator_name = Module.concat(__MODULE__, ResolutionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    try do
      assert_eventually(
        fn ->
          trace_file
          |> File.read()
          |> case do
            {:ok, trace} -> String.contains?(trace, "RESOLUTION_E2E_PASS LIN-RESOLVE")
            {:error, _} -> false
          end
        end,
        fn -> trace_debug(trace_file) end
      )

      assert_received :linear_resolution_fetch_candidate_issues
      assert_received {:linear_resolution_fetch_issue_states_by_ids, [^issue_id]}

      assert_received {:linear_resolution_comment_created, ^issue_id, comment_body}
      assert comment_body =~ "Planner: scoped the issue"
      assert comment_body =~ "Generator: implemented"
      assert comment_body =~ "Evaluator: PASS"
      assert Application.get_env(:symphony_elixir, :linear_resolution_e2e_phase_evidence_complete) == true

      assert_received {:linear_resolution_state_updated, ^issue_id, "Done"}
      assert %Issue{state: "Done"} = Application.get_env(:symphony_elixir, :linear_resolution_e2e_issue)

      assert_eventually(
        fn ->
          state = :sys.get_state(pid)

          !Map.has_key?(state.running, issue_id) and
            !Map.has_key?(state.retry_attempts, issue_id) and
            !MapSet.member?(state.claimed, issue_id)
        end,
        fn -> "orchestrator state: #{inspect(:sys.get_state(pid))}\n#{trace_debug(trace_file)}" end
      )

      trace = File.read!(trace_file)
      thread_start = thread_start!(trace)
      turn_prompt = turn_prompt!(trace)
      advertised_tool_names = Enum.map(get_in(thread_start, ["params", "dynamicTools"]) || [], & &1["name"])

      assert File.dir?(Path.join(workspace_root, "LIN-RESOLVE"))
      assert "linear_graphql" in advertised_tool_names
      assert turn_prompt =~ "LIN-RESOLVE"
      assert turn_prompt =~ "Planner -> Generator -> Evaluator"
      assert turn_prompt =~ "linear_graphql"

      assert trace =~ "PHASE:PLANNER"
      assert trace =~ "PHASE:GENERATOR"
      assert trace =~ "PHASE:EVALUATOR"
      assert trace =~ "TOOL_RESPONSE:comment"
      assert trace =~ "TOOL_RESPONSE:state"
      assert count_output_json_rpc_method(trace, "item/tool/call") == 2

      assert_order(
        trace,
        [
          "PHASE:PLANNER",
          "PHASE:GENERATOR",
          "PHASE:EVALUATOR",
          "CALL:linear_graphql:comment",
          "CALL:linear_graphql:state",
          "RESOLUTION_E2E_PASS LIN-RESOLVE"
        ]
      )

      assert count_json_rpc_method(trace, "thread/start") == 1
      assert count_json_rpc_method(trace, "turn/start") == 1
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp resolution_prompt do
    """
    Resolve tracker issue `{{ issue.identifier }}`.

    Use the Planner -> Generator -> Evaluator loop for this issue.
    Record all three phase outcomes in a tracker comment using `linear_graphql`.
    Move the issue to `Done` using `linear_graphql` only after the Evaluator passes.
    Do not use `/review` as a substitute for the Evaluator phase.
    """
  end

  defp fake_codex_app_server(trace_file, issue_id) do
    """
    #!/bin/sh
    trace_file="#{trace_file}"
    issue_id="#{issue_id}"
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
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-resolution-e2e"}}}'
          ;;
        *'"method":"turn/start"'*)
          missing=0
          require_text "LIN-RESOLVE" "issue-identifier"
          require_text "Planner -> Generator -> Evaluator" "phase-loop"
          require_text "linear_graphql" "linear-tool"
          require_text "/review" "review-mode-distinction"

          if [ "$missing" -ne 0 ]; then
            printf '%s\\n' '{"id":3,"error":{"code":-32000,"message":"missing resolution contract"}}'
            exit 1
          fi

          printf 'PROMPT_CONTRACT_OK\\n' >> "$trace_file"
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-resolution-e2e"}}}'
          emit '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"PHASE:PLANNER scoped the issue and acceptance criteria","phase":"commentary"}}}'
          emit '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"PHASE:GENERATOR implemented bounded resolution","phase":"commentary"}}}'
          emit '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"PHASE:EVALUATOR PASS verified the resolution","phase":"commentary"}}}'
          printf 'CALL:linear_graphql:comment\\n' >> "$trace_file"
          emit '{"id":101,"method":"item/tool/call","params":{"name":"linear_graphql","callId":"comment-call","threadId":"thread-resolution-e2e","turnId":"turn-resolution-e2e","arguments":{"query":"mutation ResolutionComment($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success } }","variables":{"issueId":"'"$issue_id"'","body":"Planner: scoped the issue and acceptance criteria\\nGenerator: implemented bounded resolution\\nEvaluator: PASS verified resolution\\nAll agents used before closing."}}}}'
          ;;
        *'"id":101'*)
          missing=0
          require_text '"success":true' "comment-tool-success"

          if [ "$missing" -ne 0 ]; then
            printf '%s\\n' '{"method":"turn/failed","params":{"error":"comment tool did not succeed"}}'
            exit 1
          fi

          printf 'TOOL_RESPONSE:comment:%s\\n' "$line" >> "$trace_file"
          printf 'CALL:linear_graphql:state\\n' >> "$trace_file"
          emit '{"id":102,"method":"item/tool/call","params":{"name":"linear_graphql","callId":"state-call","threadId":"thread-resolution-e2e","turnId":"turn-resolution-e2e","arguments":{"query":"mutation ResolveIssue($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: { stateId: $stateId }) { success issue { id } } }","variables":{"issueId":"'"$issue_id"'","stateId":"Done"}}}}'
          ;;
        *'"id":102'*)
          missing=0
          require_text '"success":true' "state-tool-success"

          if [ "$missing" -ne 0 ]; then
            printf '%s\\n' '{"method":"turn/failed","params":{"error":"state tool did not succeed"}}'
            exit 1
          fi

          printf 'TOOL_RESPONSE:state:%s\\n' "$line" >> "$trace_file"
          emit '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"RESOLUTION_E2E_PASS LIN-RESOLVE","phase":"final_answer"}}}'
          emit '{"method":"turn/completed","params":{"turn":{"status":"completed"},"usage":{"input_tokens":20,"output_tokens":5,"total_tokens":25}}}'
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

  defp thread_start!(trace) do
    trace
    |> json_rpc_messages()
    |> Enum.find(&match?(%{"method" => "thread/start"}, &1))
    |> case do
      nil -> flunk("expected a thread/start JSON-RPC message in #{trace}")
      payload -> payload
    end
  end

  defp count_json_rpc_method(trace, method) do
    trace
    |> json_rpc_messages()
    |> Enum.count(&match?(%{"method" => ^method}, &1))
  end

  defp count_output_json_rpc_method(trace, method) do
    trace
    |> output_json_rpc_messages()
    |> Enum.count(&match?(%{"method" => ^method}, &1))
  end

  defp json_rpc_messages(trace) do
    trace
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "JSON:"))
    |> Enum.map(fn "JSON:" <> json -> Jason.decode!(json) end)
  end

  defp output_json_rpc_messages(trace) do
    trace
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "OUT:"))
    |> Enum.map(fn "OUT:" <> json -> Jason.decode!(json) end)
  end

  defp assert_order(trace, markers) do
    markers
    |> Enum.map(fn marker ->
      case :binary.match(trace, marker) do
        {index, _length} -> {marker, index}
        :nomatch -> flunk("missing trace marker #{inspect(marker)}")
      end
    end)
    |> Enum.reduce(nil, fn
      {_marker, index}, nil ->
        index

      {marker, index}, previous ->
        assert index > previous, "expected #{inspect(marker)} to appear after previous marker"
        index
    end)
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

  defp trace_debug(trace_file) do
    case File.read(trace_file) do
      {:ok, trace} -> "fake codex trace:\n#{trace}"
      {:error, reason} -> "fake codex trace was not created: #{inspect(reason)}"
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
