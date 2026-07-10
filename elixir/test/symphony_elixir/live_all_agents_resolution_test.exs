defmodule SymphonyElixir.LiveAllAgentsResolutionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow

  @moduletag :live_all_agents_resolution
  @moduletag timeout: 420_000

  @skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_ALL_AGENTS_RESOLUTION") != "1",
                 do: "set SYMPHONY_RUN_LIVE_ALL_AGENTS_RESOLUTION=1 to run the real Codex app-server all-agents resolution test"
               )

  if @skip_reason do
    @tag skip: @skip_reason
  end

  test "real Codex resolves an issue after delegated Planner, Generator, and Evaluator complete" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-live-all-agents-resolution-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    trace_path = Path.join(test_root, "app_server_events.jsonl")
    summary_path = Path.join(test_root, "summary.txt")
    issue_id = "live-all-agents-resolution-issue"

    issue = %Issue{
      id: issue_id,
      identifier: "LIVE-ALL-AGENTS",
      title: "Resolve issue with all live agents",
      description: "Use delegated Planner, Generator, and Evaluator agents before resolving this issue.",
      state: "Todo",
      url: "https://linear.app/symphony/issue/LIVE-ALL-AGENTS",
      labels: ["symphony-live-e2e"],
      assigned_to_worker: true
    }

    previous_linear_client = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_issue = Application.get_env(:symphony_elixir, :live_all_agents_resolution_issue)
    previous_recipient = Application.get_env(:symphony_elixir, :live_all_agents_resolution_recipient)
    previous_comment_evidence = Application.get_env(:symphony_elixir, :live_all_agents_resolution_comment_evidence)

    on_exit(fn ->
      restore_app_env(:linear_client_module, previous_linear_client)
      restore_app_env(:live_all_agents_resolution_issue, previous_issue)
      restore_app_env(:live_all_agents_resolution_recipient, previous_recipient)
      restore_app_env(:live_all_agents_resolution_comment_evidence, previous_comment_evidence)

      if System.get_env("SYMPHONY_KEEP_LIVE_ALL_AGENTS_ARTIFACTS", "1") == "0" do
        File.rm_rf(test_root)
      end
    end)

    File.mkdir_p!(test_root)

    Application.put_env(:symphony_elixir, :linear_client_module, __MODULE__.FakeLinearClient)
    Application.put_env(:symphony_elixir, :live_all_agents_resolution_issue, issue)
    Application.put_env(:symphony_elixir, :live_all_agents_resolution_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "https://api.linear.app/graphql",
      tracker_api_token: "linear-token",
      tracker_project_slug: "symphony",
      tracker_required_labels: ["symphony-live-e2e"],
      tracker_active_states: ["Todo"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      max_turns: 1,
      codex_command: live_codex_command(),
      codex_approval_policy: "never",
      codex_thread_sandbox: "read-only",
      codex_turn_timeout_ms: 360_000,
      codex_stall_timeout_ms: 360_000,
      prompt: live_resolution_prompt()
    )

    run_result =
      try do
        AgentRunner.run(issue, self())
      rescue
        error -> {:raised, error, __STACKTRACE__}
      catch
        kind, reason -> {:caught, kind, reason}
      end

    messages = collect_messages()
    codex_updates = codex_updates(messages, issue_id)
    File.write!(trace_path, Enum.map_join(codex_updates, "\n", &Jason.encode!/1) <> "\n")

    assert run_result == :ok, """
    expected live AgentRunner to complete normally
    result=#{inspect(run_result)}
    trace_path=#{trace_path}
    summary_path=#{summary_path}
    """

    assert %Issue{state: "Done"} = Application.get_env(:symphony_elixir, :live_all_agents_resolution_issue)
    assert Application.get_env(:symphony_elixir, :live_all_agents_resolution_comment_evidence) == true

    assert Enum.any?(messages, &match?({:live_all_agents_resolution_comment_created, ^issue_id, _body}, &1))
    assert Enum.any?(messages, &match?({:live_all_agents_resolution_state_updated, ^issue_id, "Done"}, &1))

    assert_count_at_least(collab_tool_items(codex_updates, "spawnAgent", "completed"), 3, "completed spawnAgent calls")
    assert_count_at_least(collab_tool_items(codex_updates, "wait", "completed"), 3, "completed wait calls")

    agent_texts = agent_texts(codex_updates)
    assert Enum.any?(agent_texts, &(&1 =~ "PLANNER_CHILD_OK"))
    assert Enum.any?(agent_texts, &(&1 =~ "GENERATOR_CHILD_OK"))
    assert Enum.any?(agent_texts, &(&1 =~ "EVALUATOR_CHILD_OK"))
    assert Enum.any?(agent_texts, &(&1 =~ "LIVE_ALL_AGENTS_RESOLUTION_DONE"))

    dynamic_tool_names = dynamic_tool_call_names(codex_updates)
    assert Enum.count(dynamic_tool_names, &(&1 == "linear_graphql")) >= 2

    assert_order(
      marker_stream(codex_updates),
      [
        "spawn:Planner",
        "text:PLANNER_CHILD_OK",
        "spawn:Generator",
        "text:GENERATOR_CHILD_OK",
        "spawn:Evaluator",
        "text:EVALUATOR_CHILD_OK",
        "tool:linear_graphql",
        "text:LIVE_ALL_AGENTS_RESOLUTION_DONE"
      ]
    )

    summary = """
    trace_path=#{trace_path}
    final_issue_state=Done
    completed_spawn_agent_calls=#{length(collab_tool_items(codex_updates, "spawnAgent", "completed"))}
    completed_wait_calls=#{length(collab_tool_items(codex_updates, "wait", "completed"))}
    dynamic_tool_calls=#{inspect(dynamic_tool_names)}
    final_markers=#{inspect(Enum.filter(agent_texts, &String.contains?(&1, "LIVE_ALL_AGENTS_RESOLUTION_DONE")))}
    """

    File.write!(summary_path, summary)
    IO.puts("Live all-agents resolution summary:\n#{summary}")
  end

  defmodule __MODULE__.FakeLinearClient do
    def fetch_candidate_issues do
      case current_issue() do
        %Issue{state: "Todo"} = issue -> {:ok, [issue]}
        _ -> {:ok, []}
      end
    end

    def fetch_issues_by_states(states) do
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
      notify({:live_all_agents_resolution_graphql, query, variables, opts})

      cond do
        String.contains?(query, "commentCreate") ->
          issue_id = variable(variables, "issueId") || variable(variables, "id")
          body = variable(variables, "body") || ""
          evidence_complete? = phase_evidence_complete?(body)
          Application.put_env(:symphony_elixir, :live_all_agents_resolution_comment_evidence, evidence_complete?)
          notify({:live_all_agents_resolution_comment_created, issue_id, body})

          if evidence_complete? do
            {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
          else
            {:ok, %{"errors" => [%{"message" => "missing delegated-agent phase evidence"}]}}
          end

        String.contains?(query, "issueUpdate") ->
          issue_id = variable(variables, "issueId") || variable(variables, "id")
          state_name = variable(variables, "stateId") || variable(variables, "stateName") || "Done"

          if Application.get_env(:symphony_elixir, :live_all_agents_resolution_comment_evidence, false) do
            update_issue_state!(issue_id, state_name)
            notify({:live_all_agents_resolution_state_updated, issue_id, state_name})

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
            {:ok, %{"errors" => [%{"message" => "cannot close before all agent evidence is commented"}]}}
          end

        true ->
          {:ok, %{"data" => %{"viewer" => %{"id" => "fake-linear-viewer"}}}}
      end
    end

    defp current_issue do
      Application.get_env(:symphony_elixir, :live_all_agents_resolution_issue)
    end

    defp update_issue_state!(issue_id, state_name) do
      case current_issue() do
        %Issue{id: ^issue_id} = issue ->
          Application.put_env(:symphony_elixir, :live_all_agents_resolution_issue, %{issue | state: state_name})

        _ ->
          :ok
      end
    end

    defp phase_evidence_complete?(body) when is_binary(body) do
      body =~ "Planner: PLANNER_CHILD_OK" and
        body =~ "Generator: GENERATOR_CHILD_OK" and
        body =~ "Evaluator: EVALUATOR_CHILD_OK"
    end

    defp phase_evidence_complete?(_body), do: false

    defp variable(variables, key) when is_map(variables) do
      Map.get(variables, key) || Map.get(variables, String.to_atom(key))
    end

    defp variable(_variables, _key), do: nil

    defp notify(event) do
      if recipient = Application.get_env(:symphony_elixir, :live_all_agents_resolution_recipient) do
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

  defp live_codex_command do
    System.get_env("SYMPHONY_LIVE_ALL_AGENTS_CODEX_COMMAND", "codex app-server")
  end

  defp live_resolution_prompt do
    """
    You are a Symphony live all-agents resolution e2e test.
    Do not run shell commands, edit files, or ask for user input.

    Resolve tracker issue `{{ issue.identifier }}`.

    Use exactly three real delegated child agents through the built-in delegated-agent tool, in this order:
    1. Planner child: ask it to return exactly PLANNER_CHILD_OK.
    2. Generator child: ask it to return exactly GENERATOR_CHILD_OK.
    3. Evaluator child: ask it to return exactly EVALUATOR_CHILD_OK.

    Wait for each child before moving to the next phase.
    If no real delegated child-agent tool is available, do not call `linear_graphql`; answer exactly LIVE_ALL_AGENTS_RESOLUTION_BLOCKED_NO_DELEGATED_TOOL.

    Only after all three child results have returned, invoke the client-side dynamic tool named exactly `linear_graphql`.
    Do not use any MCP connector, plugin, app tool, or tool named `linear_save_comment`, `linear_update_issue`, `commentCreate`, or `issueUpdate` directly.
    The only allowed Linear operation surface in this test is the dynamic tool named exactly `linear_graphql`; using any other Linear surface will fail the non-interactive test.

    First call `linear_graphql` with a raw GraphQL `commentCreate` mutation for issue id `{{ issue.id }}` and this exact phase evidence in the `body` variable:
    Planner: PLANNER_CHILD_OK
    Generator: GENERATOR_CHILD_OK
    Evaluator: EVALUATOR_CHILD_OK

    Then call `linear_graphql` with a raw GraphQL `issueUpdate` mutation to move issue id `{{ issue.id }}` to state `Done`.
    After both Linear tool calls succeed, answer exactly LIVE_ALL_AGENTS_RESOLUTION_DONE.
    """
  end

  defp collect_messages(acc \\ []) do
    receive do
      message -> collect_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp codex_updates(messages, issue_id) do
    messages
    |> Enum.flat_map(fn
      {:codex_worker_update, ^issue_id, update} -> [update]
      _ -> []
    end)
  end

  defp collab_tool_items(codex_updates, tool, status) do
    codex_updates
    |> Enum.flat_map(&payload_items/1)
    |> Enum.filter(fn item ->
      item["type"] == "collabAgentToolCall" and item["tool"] == tool and item["status"] == status
    end)
  end

  defp dynamic_tool_call_names(codex_updates) do
    codex_updates
    |> Enum.filter(&(get_in(&1, [:payload, "method"]) == "item/tool/call"))
    |> Enum.map(fn update ->
      params = get_in(update, [:payload, "params"]) || %{}
      Map.get(params, "tool") || Map.get(params, "name")
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp agent_texts(codex_updates) do
    codex_updates
    |> Enum.flat_map(&payload_items/1)
    |> Enum.flat_map(fn
      %{"type" => "agentMessage", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
  end

  defp payload_items(%{payload: %{"params" => %{"item" => item}}}) when is_map(item), do: [item]
  defp payload_items(_update), do: []

  defp marker_stream(codex_updates) do
    codex_updates
    |> Enum.flat_map(fn update ->
      payload = Map.get(update, :payload) || %{}

      cond do
        get_in(payload, ["params", "item", "type"]) == "collabAgentToolCall" ->
          item = get_in(payload, ["params", "item"])
          collab_marker(item)

        get_in(payload, ["params", "item", "type"]) == "agentMessage" ->
          text = get_in(payload, ["params", "item", "text"]) || ""
          text_markers(text)

        get_in(payload, ["method"]) == "item/tool/call" ->
          params = get_in(payload, ["params"]) || %{}
          ["tool:#{Map.get(params, "tool") || Map.get(params, "name")}"]

        true ->
          []
      end
    end)
  end

  defp collab_marker(%{"tool" => "spawnAgent", "status" => "completed", "prompt" => prompt}) when is_binary(prompt) do
    cond do
      prompt =~ "Planner" or prompt =~ "PLANNER_CHILD_OK" -> ["spawn:Planner"]
      prompt =~ "Generator" or prompt =~ "GENERATOR_CHILD_OK" -> ["spawn:Generator"]
      prompt =~ "Evaluator" or prompt =~ "EVALUATOR_CHILD_OK" -> ["spawn:Evaluator"]
      true -> []
    end
  end

  defp collab_marker(_item), do: []

  defp text_markers(text) do
    ["PLANNER_CHILD_OK", "GENERATOR_CHILD_OK", "EVALUATOR_CHILD_OK", "LIVE_ALL_AGENTS_RESOLUTION_DONE"]
    |> Enum.filter(&String.contains?(text, &1))
    |> Enum.map(&"text:#{&1}")
  end

  defp assert_count_at_least(collection, minimum, label) do
    actual = length(collection)
    assert actual >= minimum, "expected at least #{minimum} #{label}, got #{actual}"
  end

  defp assert_order(stream, markers) do
    {_remaining_stream, _matched_markers} =
      Enum.reduce(markers, {stream, []}, fn marker, {remaining_stream, matched_markers} ->
        case Enum.split_while(remaining_stream, &(&1 != marker)) do
          {_skipped, []} ->
            flunk("missing marker #{inspect(marker)} after #{inspect(Enum.reverse(matched_markers))}; stream=#{inspect(stream)}")

          {_skipped, [_found | rest]} ->
            {rest, [marker | matched_markers]}
        end
      end)

    :ok
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
