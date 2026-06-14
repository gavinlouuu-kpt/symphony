defmodule SymphonyElixir.ContainerOrchestratorTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.ContainerOrchestrator

  setup do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :container_command_runner)
      Application.delete_env(:symphony_elixir, :pull_request_resolver)
    end)

    :ok
  end

  describe "setup/2" do
    test "is a no-op when no features are configured" do
      write_workflow_file!(Workflow.workflow_file_path(),
        container_enabled: true,
        container_features: []
      )

      assert ContainerOrchestrator.setup(%{container_name: "symphony-agent-MT-1"}, "/tmp/ws") == :noop
    end

    test "is a no-op when configured features resolve to nothing" do
      write_workflow_file!(Workflow.workflow_file_path(),
        container_enabled: true,
        container_features: ["made-up"]
      )

      log =
        capture_log(fn ->
          assert ContainerOrchestrator.setup(%{container_name: "symphony-agent-MT-1"}, "/tmp/ws") ==
                   :noop
        end)

      assert log =~ "Ignoring unknown container feature"
    end

    test "is a no-op for a missing container or non-binary workspace" do
      assert ContainerOrchestrator.setup(nil, "/tmp/ws") == :noop
      assert ContainerOrchestrator.setup(%{container_name: "x"}, 123) == :noop
    end

    test "provisions resolved features through the container engine" do
      write_workflow_file!(Workflow.workflow_file_path(),
        container_enabled: true,
        container_features: ["make"]
      )

      test_pid = self()

      Application.put_env(:symphony_elixir, :container_command_runner, fn engine, args ->
        send(test_pid, {:engine_cmd, engine, args})
        {:ok, {"", 0}}
      end)

      log =
        capture_log(fn ->
          assert {:ok, result} =
                   ContainerOrchestrator.setup(%{container_name: "symphony-agent-MT-1"}, "/tmp/ws")

          send(test_pid, {:result, result})
        end)

      assert_received {:result, %{provisioned: ["make"], skipped: [], failed: []}}
      assert_received {:engine_cmd, "docker", ["exec", "symphony-agent-MT-1", "bash", "-lc", _script]}
      assert log =~ "Setting up container features"
    end
  end

  describe "diagnostics/1" do
    test "summarizes a healthy desktop" do
      write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)

      Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, ["exec", _name, "bash", "-lc", script] ->
        cond do
          script == "echo running" -> {:ok, {"running\n", 0}}
          String.starts_with?(script, "ls -1") -> {:ok, {"make\ndocker\n", 0}}
          String.starts_with?(script, "tail -n 40") -> {:ok, {"line1\nline2\n", 0}}
        end
      end)

      diagnostics = ContainerOrchestrator.diagnostics("MT-70")

      assert diagnostics.container_name == "symphony-agent-MT-70"
      assert diagnostics.status == "running"
      assert diagnostics.features == ["make", "docker"]
      assert diagnostics.logs == "line1\nline2"
    end

    test "tolerates a stopped desktop with no features, logs, or status" do
      write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)

      Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, ["exec", _name, "bash", "-lc", script] ->
        cond do
          script == "echo running" -> {:ok, {"", 1}}
          String.starts_with?(script, "ls -1") -> {:error, :engine_unreachable}
          String.starts_with?(script, "tail -n 40") -> {:ok, {"   \n", 0}}
        end
      end)

      diagnostics = ContainerOrchestrator.diagnostics("MT-71")

      assert diagnostics.status == nil
      assert diagnostics.features == []
      assert diagnostics.logs == nil
    end

    test "tolerates engine errors on status and logs" do
      write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)

      Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, ["exec", _name, "bash", "-lc", script] ->
        cond do
          script == "echo running" -> {:error, :engine_unreachable}
          String.starts_with?(script, "ls -1") -> {:ok, {"browser\n", 0}}
          String.starts_with?(script, "tail -n 40") -> {:error, :engine_unreachable}
        end
      end)

      diagnostics = ContainerOrchestrator.diagnostics("MT-72")

      assert diagnostics.status == nil
      assert diagnostics.features == ["browser"]
      assert diagnostics.logs == nil
    end
  end

  test "review/1 delegates to the desktop reaper" do
    # Container mode disabled by default, so there is nothing to reap.
    assert ContainerOrchestrator.review([]) == []
  end
end
