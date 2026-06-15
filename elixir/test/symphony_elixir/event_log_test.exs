defmodule SymphonyElixir.EventLogTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.EventLog

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-eventlog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    name = :"event_log_#{System.unique_integer([:positive])}"
    start_supervised!({EventLog, name: name, dir: dir, memory_limit: 3})

    {:ok, dir: dir, name: name}
  end

  test "records significant events in chronological order", %{name: name} do
    EventLog.record("MT-1", %{event: "turn/started", message: "turn started"}, name)
    EventLog.record("MT-1", %{event: "item/completed", message: "item completed"}, name)

    events = EventLog.list("MT-1", [], name)

    assert Enum.map(events, & &1.message) == ["turn started", "item completed"]
    assert Enum.map(events, & &1.seq) == [1, 2]
  end

  test "drops streaming and token-count noise" do
    refute EventLog.significant?("item/agentMessage/delta")
    refute EventLog.significant?("thread/tokenUsage/updated")
    refute EventLog.significant?(:codex_event_token_count)
    assert EventLog.significant?("turn/completed")
    assert EventLog.significant?("item/commandExecution/requestApproval")
  end

  test "noisy events are not persisted", %{name: name} do
    EventLog.record("MT-2", %{event: "item/reasoning/textDelta", message: "reasoning streaming"}, name)
    EventLog.record("MT-2", %{event: "turn/completed", message: "turn completed"}, name)

    assert [%{message: "turn completed"}] = EventLog.list("MT-2", [], name)
  end

  test "limit returns most recent events chronologically", %{name: name} do
    for n <- 1..5 do
      EventLog.record("MT-3", %{event: "turn/started", message: "turn #{n}"}, name)
    end

    events = EventLog.list("MT-3", [limit: 2], name)
    assert Enum.map(events, & &1.message) == ["turn 4", "turn 5"]
  end

  test "memory is bounded but the durable file keeps full history", %{name: name, dir: dir} do
    for n <- 1..5 do
      EventLog.record("MT-4", %{event: "turn/started", message: "turn #{n}"}, name)
    end

    # memory_limit is 3, so only the most recent three remain in ETS
    assert EventLog.list("MT-4", [], name) |> length() == 3

    lines =
      dir
      |> Path.join("MT-4.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert length(lines) == 5
  end

  test "hydrates from the durable file after a restart", %{dir: dir} do
    name = :"event_log_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({EventLog, name: name, dir: dir, memory_limit: 10}, id: :first))

    EventLog.record("MT-5", %{event: "turn/started", message: "before restart"}, name)
    assert EventLog.list("MT-5", [], name) |> length() == 1

    stop_supervised!(:first)

    restarted = :"event_log_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({EventLog, name: restarted, dir: dir, memory_limit: 10}, id: :second))

    assert [%{message: "before restart"}] = EventLog.list("MT-5", [], restarted)
  end

  test "list returns empty when the server is not running" do
    assert EventLog.list("MT-404", [], :nonexistent_event_log) == []
  end
end
