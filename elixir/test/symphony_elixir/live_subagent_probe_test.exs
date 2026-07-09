defmodule SymphonyElixir.LiveSubagentProbeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow

  @moduletag :live_subagent_probe
  @moduletag timeout: 240_000

  @skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_SUBAGENT_PROBE") != "1",
                 do: "set SYMPHONY_RUN_LIVE_SUBAGENT_PROBE=1 to run the real Codex app-server sub-agent probe"
               )

  if @skip_reason do
    @tag skip: @skip_reason
  end

  test "real Codex app-server reports whether delegated sub-agent tools are available" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-live-subagent-probe-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "PROBE-SUBAGENT")
    trace_path = Path.join(test_root, "app_server_events.jsonl")
    summary_path = Path.join(test_root, "summary.txt")

    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["open"],
      tracker_terminal_states: ["closed"],
      workspace_root: workspace_root,
      codex_command: live_codex_command(),
      codex_approval_policy: "never",
      codex_turn_timeout_ms: 180_000,
      codex_stall_timeout_ms: 180_000
    )

    issue = %Issue{
      id: "probe-subagent-tool",
      identifier: "PROBE-SUBAGENT",
      title: "Sub-agent tool availability probe",
      description: "Check whether a Symphony-launched Codex app-server session has a delegated-agent tool.",
      state: "open",
      url: "https://example.invalid/PROBE-SUBAGENT",
      labels: []
    }

    on_message = fn message ->
      File.write!(trace_path, Jason.encode!(message) <> "\n", [:append])
    end

    assert {:ok, %{result: :turn_completed}} =
             AppServer.run(workspace, probe_prompt(), issue, on_message: on_message)

    trace = File.read!(trace_path)
    messages = decode_trace!(trace)
    final_text = final_agent_text!(messages)
    tool_call_names = tool_call_names(messages)

    summary = """
    trace_path=#{trace_path}
    final_text=#{final_text}
    tool_call_names=#{inspect(tool_call_names)}
    """

    File.write!(summary_path, summary)
    IO.puts("Live sub-agent probe summary:\n#{summary}")

    case expected_subagent_tool() do
      :available ->
        assert final_text =~ "SUBAGENT_TOOL_AVAILABLE"
        assert final_text =~ "SUBAGENT_PROBE_CHILD_OK"

      :unavailable ->
        assert String.trim(final_text) == "NO_DELEGATED_AGENT_TOOL_AVAILABLE"
        refute Enum.any?(tool_call_names, &delegated_tool_name?/1)

      :any ->
        assert String.trim(final_text) == "NO_DELEGATED_AGENT_TOOL_AVAILABLE" or
                 (final_text =~ "SUBAGENT_TOOL_AVAILABLE" and final_text =~ "SUBAGENT_PROBE_CHILD_OK")
    end
  end

  defp live_codex_command do
    System.get_env("SYMPHONY_LIVE_SUBAGENT_CODEX_COMMAND", "codex app-server")
  end

  defp expected_subagent_tool do
    case System.get_env("SYMPHONY_EXPECT_SUBAGENT_TOOL", "any") do
      "true" -> :available
      "1" -> :available
      "available" -> :available
      "false" -> :unavailable
      "0" -> :unavailable
      "unavailable" -> :unavailable
      _ -> :any
    end
  end

  defp probe_prompt do
    """
    You are a Codex app-server delegated-agent capability probe launched by Symphony.
    Do not run shell commands, do not edit files, do not use Linear, and do not ask for user input.

    Inspect only the active tools available to this spawned Codex session.
    If you have a real built-in delegated sub-agent tool such as multi_agent_v1.spawn_agent, spawn_agent, or another multi-agent delegation tool, call it once with this trivial child task: Return SUBAGENT_PROBE_CHILD_OK and stop.
    After the child returns, answer with SUBAGENT_TOOL_AVAILABLE, the exact tool name you used, and the child result.

    If no real delegated sub-agent tool is listed in your active tools, answer exactly:
    NO_DELEGATED_AGENT_TOOL_AVAILABLE
    """
  end

  defp decode_trace!(trace) do
    trace
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp final_agent_text!(messages) do
    root_thread_id = root_thread_id!(messages)

    messages
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      case {get_in(message, ["payload", "method"]), get_in(message, ["payload", "params", "item"])} do
        {"item/completed", %{"type" => "agentMessage", "phase" => "final_answer", "text" => text}}
        when is_binary(text) ->
          if get_in(message, ["payload", "params", "threadId"]) == root_thread_id do
            String.trim(text)
          end

        _ ->
          nil
      end
    end)
    |> case do
      nil -> flunk("expected a final agentMessage in the live sub-agent probe trace")
      text -> text
    end
  end

  defp root_thread_id!(messages) do
    messages
    |> Enum.find_value(fn
      %{"event" => "session_started", "thread_id" => thread_id} when is_binary(thread_id) ->
        thread_id

      %{"event" => "session_started", "payload" => %{"thread_id" => thread_id}} when is_binary(thread_id) ->
        thread_id

      _ ->
        nil
    end)
    |> case do
      nil -> flunk("expected session_started with root thread_id in live sub-agent probe trace")
      thread_id -> thread_id
    end
  end

  defp tool_call_names(messages) do
    dynamic_tool_calls =
      messages
      |> Enum.filter(&(get_in(&1, ["payload", "method"]) == "item/tool/call"))
      |> Enum.map(fn message ->
        params = get_in(message, ["payload", "params"]) || %{}
        Map.get(params, "tool") || Map.get(params, "name")
      end)

    collab_tool_calls =
      messages
      |> Enum.flat_map(fn message ->
        case get_in(message, ["payload", "params", "item"]) do
          %{"type" => "collabAgentToolCall", "tool" => tool} when is_binary(tool) -> [tool]
          _ -> []
        end
      end)

    (dynamic_tool_calls ++ collab_tool_calls)
    |> Enum.reject(&is_nil/1)
  end

  defp delegated_tool_name?(tool_name) when is_binary(tool_name) do
    normalized = String.downcase(tool_name)

    String.contains?(normalized, "spawn_agent") or String.contains?(normalized, "spawnagent") or
      String.contains?(normalized, "multi_agent")
  end

  defp delegated_tool_name?(_tool_name), do: false
end
