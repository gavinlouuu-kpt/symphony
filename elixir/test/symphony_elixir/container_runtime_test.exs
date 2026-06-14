defmodule SymphonyElixir.ContainerRuntimeTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.ContainerRuntime

  setup do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :container_command_runner)
      Application.delete_env(:symphony_elixir, :tailscale_command_runner)
      Application.delete_env(:symphony_elixir, :pull_request_resolver)
    end)

    :ok
  end

  test "container config defaults are disabled and sane" do
    settings = Config.settings!().container

    assert settings.enabled == false
    assert settings.engine == "docker"
    assert settings.image == "symphony-agent-desktop:latest"
    assert settings.name_prefix == "symphony-agent-"
    assert settings.workspace_mount == "/workspace"
    assert settings.novnc_container_port == 6080
    assert settings.novnc_host == "127.0.0.1"
    assert settings.novnc_advertise_host == nil
    assert settings.extra_run_args == []
    assert settings.features == ["auto"]
    assert settings.keep_pr_desktops == true

    refute ContainerRuntime.enabled?()
  end

  test "container config accepts overrides and rejects unknown engines" do
    write_workflow_file!(Workflow.workflow_file_path(),
      container_enabled: true,
      container_engine: "podman",
      container_image: "my-desktop:1",
      container_novnc_host: "0.0.0.0",
      container_extra_run_args: ["--memory", "2g"]
    )

    settings = Config.settings!().container
    assert settings.enabled == true
    assert settings.engine == "podman"
    assert settings.image == "my-desktop:1"
    assert settings.novnc_host == "0.0.0.0"
    assert settings.extra_run_args == ["--memory", "2g"]
    assert ContainerRuntime.enabled?()

    write_workflow_file!(Workflow.workflow_file_path(), container_engine: "lxc")

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "container.engine"
    refute ContainerRuntime.enabled?()
  end

  test "ensure_started runs a fresh container and resolves the published noVNC port" do
    write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)
    test_pid = self()

    Application.put_env(:symphony_elixir, :container_command_runner, fn engine, args ->
      send(test_pid, {:engine_cmd, engine, args})

      case args do
        ["inspect" | _] -> {:ok, {"Error: no such container", 1}}
        ["run" | _] -> {:ok, {"abc123def\n", 0}}
        ["port" | _] -> {:ok, {"127.0.0.1:49160\n", 0}}
      end
    end)

    assert {:ok, info} = ContainerRuntime.ensure_started("MT-12/demo", "/tmp/workspaces/MT-12")

    assert info.container_id == "abc123def"
    assert info.container_name == "symphony-agent-MT-12_demo"
    assert info.image == "symphony-agent-desktop:latest"
    assert info.engine == "docker"
    assert info.workspace_mount == "/workspace"
    assert info.novnc_port == 49_160
    assert info.novnc_url == "http://127.0.0.1:49160/vnc.html?autoconnect=1&resize=scale"

    assert_received {:engine_cmd, "docker", ["inspect" | _]}
    assert_received {:engine_cmd, "docker", ["run" | run_args]}
    assert_received {:engine_cmd, "docker", ["port", "symphony-agent-MT-12_demo", "6080/tcp"]}

    assert "--volume" in run_args
    assert "/tmp/workspaces/MT-12:/workspace" in run_args
    assert "--publish" in run_args
    assert "127.0.0.1::6080" in run_args
    assert List.last(run_args) == "symphony-agent-desktop:latest"
  end

  test "ensure_started binds and advertises via Tailscale when novnc_host is tailscale" do
    write_workflow_file!(Workflow.workflow_file_path(),
      container_enabled: true,
      container_novnc_host: "tailscale"
    )

    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn
      ["ip", "-4"] -> {:ok, {"100.64.0.7\n", 0}}
      ["status", "--json"] -> {:ok, {~s({"Self":{"DNSName":"dev-server.tail1234.ts.net."}}), 0}}
    end)

    test_pid = self()

    Application.put_env(:symphony_elixir, :container_command_runner, fn engine, args ->
      send(test_pid, {:engine_cmd, engine, args})

      case args do
        ["inspect" | _] -> {:ok, {"", 1}}
        ["run" | _] -> {:ok, {"ts123\n", 0}}
        ["port" | _] -> {:ok, {"100.64.0.7:49500\n", 0}}
      end
    end)

    assert {:ok, info} = ContainerRuntime.ensure_started("MT-30", "/tmp/workspaces/MT-30")

    assert info.novnc_port == 49_500
    assert info.novnc_url == "http://dev-server.tail1234.ts.net:49500/vnc.html?autoconnect=1&resize=scale"

    assert_received {:engine_cmd, "docker", ["run" | run_args]}
    assert "100.64.0.7::6080" in run_args
  end

  test "ensure_started falls back to the Tailscale IP in URLs when MagicDNS is unavailable" do
    write_workflow_file!(Workflow.workflow_file_path(),
      container_enabled: true,
      container_novnc_host: "tailscale"
    )

    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn
      ["ip", "-4"] -> {:ok, {"100.64.0.7\n", 0}}
      ["status", "--json"] -> {:ok, {"{}", 0}}
    end)

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, args ->
      case args do
        ["inspect" | _] -> {:ok, {"", 1}}
        ["run" | _] -> {:ok, {"ts123\n", 0}}
        ["port" | _] -> {:ok, {"100.64.0.7:49501\n", 0}}
      end
    end)

    assert {:ok, info} = ContainerRuntime.ensure_started("MT-31", "/tmp/workspaces/MT-31")
    assert info.novnc_url == "http://100.64.0.7:49501/vnc.html?autoconnect=1&resize=scale"

    # If Tailscale becomes unavailable after the bind address was resolved,
    # URLs fall back to the already-bound address.
    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn
      ["ip", "-4"] ->
        case Process.get(:tailscale_ip_calls, 0) do
          0 ->
            Process.put(:tailscale_ip_calls, 1)
            {:ok, {"100.64.0.7\n", 0}}

          _ ->
            {:ok, {"Logged out.", 1}}
        end

      ["status", "--json"] ->
        {:ok, {"{}", 0}}
    end)

    assert {:ok, info} = ContainerRuntime.ensure_started("MT-31", "/tmp/workspaces/MT-31")
    assert info.novnc_url == "http://100.64.0.7:49501/vnc.html?autoconnect=1&resize=scale"
  end

  test "ensure_started honors an explicit advertise host, including the tailscale shorthand" do
    write_workflow_file!(Workflow.workflow_file_path(),
      container_enabled: true,
      container_novnc_host: "0.0.0.0",
      container_novnc_advertise_host: "desktops.example.internal"
    )

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, args ->
      case args do
        ["inspect" | _] -> {:ok, {"", 1}}
        ["run" | _] -> {:ok, {"adv123\n", 0}}
        ["port" | _] -> {:ok, {"0.0.0.0:49502\n", 0}}
      end
    end)

    assert {:ok, info} = ContainerRuntime.ensure_started("MT-32", "/tmp/workspaces/MT-32")
    assert info.novnc_url == "http://desktops.example.internal:49502/vnc.html?autoconnect=1&resize=scale"

    write_workflow_file!(Workflow.workflow_file_path(),
      container_enabled: true,
      container_novnc_host: "0.0.0.0",
      container_novnc_advertise_host: "tailscale"
    )

    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn
      ["status", "--json"] -> {:ok, {~s({"Self":{"DNSName":"dev-server.tail1234.ts.net."}}), 0}}
    end)

    assert {:ok, info} = ContainerRuntime.ensure_started("MT-32", "/tmp/workspaces/MT-32")
    assert info.novnc_url == "http://dev-server.tail1234.ts.net:49502/vnc.html?autoconnect=1&resize=scale"
  end

  test "ensure_started surfaces Tailscale resolution failures" do
    write_workflow_file!(Workflow.workflow_file_path(),
      container_enabled: true,
      container_novnc_host: "tailscale"
    )

    Application.put_env(:symphony_elixir, :tailscale_command_runner, fn _args ->
      {:error, :tailscale_not_found}
    end)

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, _args ->
      flunk("container engine should not be invoked when Tailscale resolution fails")
    end)

    assert {:error, :tailscale_not_found} = ContainerRuntime.ensure_started("MT-33", "/tmp/workspaces/MT-33")
  end

  test "ensure_started reuses a running container without starting a new one" do
    write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)
    test_pid = self()

    Application.put_env(:symphony_elixir, :container_command_runner, fn engine, args ->
      send(test_pid, {:engine_cmd, engine, args})

      case args do
        ["inspect" | _] -> {:ok, {"existing123 true\n", 0}}
        ["port" | _] -> {:ok, {"0.0.0.0:41001\n127.0.0.1:41001\n", 0}}
      end
    end)

    assert {:ok, info} = ContainerRuntime.ensure_started("MT-13", "/tmp/workspaces/MT-13")
    assert info.container_id == "existing123"
    assert info.novnc_port == 41_001

    refute_received {:engine_cmd, _engine, ["run" | _]}
  end

  test "ensure_started replaces a stopped container" do
    write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)
    test_pid = self()

    Application.put_env(:symphony_elixir, :container_command_runner, fn engine, args ->
      send(test_pid, {:engine_cmd, engine, args})

      case args do
        ["inspect" | _] -> {:ok, {"stale123 false\n", 0}}
        ["rm" | _] -> {:ok, {"stale123\n", 0}}
        ["run" | _] -> {:ok, {"fresh456\n", 0}}
        ["port" | _] -> {:ok, {"127.0.0.1:41002\n", 0}}
      end
    end)

    assert {:ok, info} = ContainerRuntime.ensure_started("MT-14", "/tmp/workspaces/MT-14")
    assert info.container_id == "fresh456"

    assert_received {:engine_cmd, "docker", ["rm", "--force", "symphony-agent-MT-14"]}
    assert_received {:engine_cmd, "docker", ["run" | _]}
  end

  test "ensure_started surfaces stale-container replacement failures" do
    write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, args ->
      case args do
        ["inspect" | _] -> {:ok, {"stale123 false\n", 0}}
        ["rm" | _] -> {:ok, {"cannot remove", 1}}
      end
    end)

    assert {:error, {:container_remove_failed, "symphony-agent-MT-17", 1, "cannot remove"}} =
             ContainerRuntime.ensure_started("MT-17", "/tmp/workspaces/MT-17")

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, args ->
      case args do
        ["inspect" | _] -> {:ok, {"stale123 false\n", 0}}
        ["rm" | _] -> {:error, :engine_unreachable}
      end
    end)

    assert {:error, :engine_unreachable} = ContainerRuntime.ensure_started("MT-17", "/tmp/workspaces/MT-17")
  end

  test "ensure_started surfaces start and port lookup failures" do
    write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, args ->
      case args do
        ["inspect" | _] -> {:ok, {"", 1}}
        ["run" | _] -> {:ok, {"image not found", 125}}
      end
    end)

    assert {:error, {:container_start_failed, "symphony-agent-MT-15", 125, "image not found"}} =
             ContainerRuntime.ensure_started("MT-15", "/tmp/workspaces/MT-15")

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, args ->
      case args do
        ["inspect" | _] -> {:ok, {"", 1}}
        ["run" | _] -> {:ok, {"id789\n", 0}}
        ["port" | _] -> {:ok, {"garbled", 0}}
      end
    end)

    assert {:error, {:container_port_lookup_failed, "symphony-agent-MT-15", :unparsable_output, "garbled"}} =
             ContainerRuntime.ensure_started("MT-15", "/tmp/workspaces/MT-15")

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, args ->
      case args do
        ["inspect" | _] -> {:ok, {"", 1}}
        ["run" | _] -> {:error, :engine_unreachable}
      end
    end)

    assert {:error, :engine_unreachable} = ContainerRuntime.ensure_started("MT-15", "/tmp/workspaces/MT-15")

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, args ->
      case args do
        ["inspect" | _] -> {:ok, {"", 1}}
        ["run" | _] -> {:ok, {"id789\n", 0}}
        ["port" | _] -> {:ok, {"port lookup error", 1}}
      end
    end)

    assert {:error, {:container_port_lookup_failed, "symphony-agent-MT-15", 1, "port lookup error"}} =
             ContainerRuntime.ensure_started("MT-15", "/tmp/workspaces/MT-15")

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, args ->
      case args do
        ["inspect" | _] -> {:ok, {"", 1}}
        ["run" | _] -> {:ok, {"id789\n", 0}}
        ["port" | _] -> {:error, :engine_unreachable}
      end
    end)

    assert {:error, :engine_unreachable} = ContainerRuntime.ensure_started("MT-15", "/tmp/workspaces/MT-15")

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, _args ->
      {:error, {:container_engine_not_found, "docker"}}
    end)

    assert {:error, {:container_engine_not_found, "docker"}} =
             ContainerRuntime.ensure_started("MT-15", "/tmp/workspaces/MT-15")
  end

  test "default command runner shells out to the engine found on PATH" do
    write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)
    Application.delete_env(:symphony_elixir, :container_command_runner)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-container-fake-docker-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    fake_docker = Path.join(test_root, "docker")

    File.write!(fake_docker, """
    #!/bin/sh
    case "$1" in
      inspect) echo "no such container"; exit 1 ;;
      run) echo "fakeid123" ;;
      port) echo "127.0.0.1:45678" ;;
    esac
    """)

    File.chmod!(fake_docker, 0o755)

    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    System.put_env("PATH", test_root)

    assert {:ok, info} = ContainerRuntime.ensure_started("MT-20", "/tmp/workspaces/MT-20")
    assert info.container_id == "fakeid123"
    assert info.novnc_port == 45_678

    empty_path = Path.join(test_root, "empty")
    File.mkdir_p!(empty_path)
    System.put_env("PATH", empty_path)

    assert {:error, {:container_engine_not_found, "docker"}} =
             ContainerRuntime.ensure_started("MT-20", "/tmp/workspaces/MT-20")
  end

  test "remove_for_issue force-removes the container only when container mode is enabled" do
    test_pid = self()

    Application.put_env(:symphony_elixir, :container_command_runner, fn engine, args ->
      send(test_pid, {:engine_cmd, engine, args})
      {:ok, {"", 0}}
    end)

    assert :ok = ContainerRuntime.remove_for_issue("MT-16")
    refute_received {:engine_cmd, _engine, _args}

    write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)

    assert :ok = ContainerRuntime.remove_for_issue("MT-16")
    assert_received {:engine_cmd, "docker", ["rm", "--force", "symphony-agent-MT-16"]}

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, _args ->
      {:ok, {"no such container", 1}}
    end)

    assert :ok = ContainerRuntime.remove_for_issue("MT-16")

    Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, _args ->
      {:error, {:container_engine_not_found, "docker"}}
    end)

    log =
      capture_log(fn ->
        assert :ok = ContainerRuntime.remove_for_issue("MT-16")
      end)

    assert log =~ "Failed to remove agent container"
  end

  test "container_name sanitizes issue identifiers" do
    assert ContainerRuntime.container_name("MT 1/weird:id") == "symphony-agent-MT_1_weird_id"
  end

  test "run labels the container with its issue identifier for later reaping" do
    write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)
    test_pid = self()

    Application.put_env(:symphony_elixir, :container_command_runner, fn engine, args ->
      send(test_pid, {:engine_cmd, engine, args})

      case args do
        ["inspect" | _] -> {:ok, {"", 1}}
        ["run" | _] -> {:ok, {"abc\n", 0}}
        ["port" | _] -> {:ok, {"127.0.0.1:5000\n", 0}}
      end
    end)

    assert {:ok, _info} = ContainerRuntime.ensure_started("MT-50", "/tmp/workspaces/MT-50")
    assert_received {:engine_cmd, "docker", ["run" | run_args]}
    assert "symphony.issue=MT-50" in run_args
  end

  test "engine_exec runs a script inside the container" do
    write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)
    test_pid = self()

    Application.put_env(:symphony_elixir, :container_command_runner, fn engine, args ->
      send(test_pid, {:engine_cmd, engine, args})
      {:ok, {"done\n", 0}}
    end)

    assert {:ok, {"done\n", 0}} = ContainerRuntime.engine_exec("symphony-agent-MT-1", "echo hi")
    assert_received {:engine_cmd, "docker", ["exec", "symphony-agent-MT-1", "bash", "-lc", "echo hi"]}
  end

  describe "cleanup_for_issue" do
    test "retains the desktop while the PR is open" do
      write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)
      Application.put_env(:symphony_elixir, :pull_request_resolver, fn _workspace -> :open end)

      Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, _args ->
        flunk("container must not be removed while its PR is open")
      end)

      assert :retained = ContainerRuntime.cleanup_for_issue("MT-60")
    end

    test "removes the desktop once the PR is merged or closed" do
      write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)
      Application.put_env(:symphony_elixir, :pull_request_resolver, fn _workspace -> :merged end)
      test_pid = self()

      Application.put_env(:symphony_elixir, :container_command_runner, fn engine, args ->
        send(test_pid, {:engine_cmd, engine, args})
        {:ok, {"", 0}}
      end)

      assert :removed = ContainerRuntime.cleanup_for_issue("MT-61")
      assert_received {:engine_cmd, "docker", ["rm", "--force", "symphony-agent-MT-61"]}
    end

    test "removes the desktop when the workspace path cannot be resolved" do
      regular_file =
        Path.join(System.tmp_dir!(), "symphony-not-a-dir-#{System.unique_integer([:positive])}")

      File.write!(regular_file, "")
      on_exit(fn -> File.rm_rf(regular_file) end)

      write_workflow_file!(Workflow.workflow_file_path(),
        container_enabled: true,
        workspace_root: Path.join(regular_file, "nested")
      )

      Application.put_env(:symphony_elixir, :pull_request_resolver, fn _workspace ->
        flunk("PR status must not be checked when the workspace path is unresolved")
      end)

      test_pid = self()

      Application.put_env(:symphony_elixir, :container_command_runner, fn engine, args ->
        send(test_pid, {:engine_cmd, engine, args})
        {:ok, {"", 0}}
      end)

      assert :removed = ContainerRuntime.cleanup_for_issue("MT-62")
      assert_received {:engine_cmd, "docker", ["rm", "--force", "symphony-agent-MT-62"]}
    end

    test "force-removes without a PR check when retention is disabled" do
      write_workflow_file!(Workflow.workflow_file_path(),
        container_enabled: true,
        container_keep_pr_desktops: false
      )

      Application.put_env(:symphony_elixir, :pull_request_resolver, fn _workspace ->
        flunk("PR status must not be checked when retention is disabled")
      end)

      test_pid = self()

      Application.put_env(:symphony_elixir, :container_command_runner, fn engine, args ->
        send(test_pid, {:engine_cmd, engine, args})
        {:ok, {"", 0}}
      end)

      assert :removed = ContainerRuntime.cleanup_for_issue("MT-63")
      assert_received {:engine_cmd, "docker", ["rm", "--force", "symphony-agent-MT-63"]}
    end

    test "is a no-op signal when container mode is disabled or routed to a worker" do
      Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, _args ->
        flunk("engine must not be invoked when container mode is disabled")
      end)

      assert :removed = ContainerRuntime.cleanup_for_issue("MT-64")

      write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)
      assert :removed = ContainerRuntime.cleanup_for_issue("MT-64", "dm-dev2")
    end
  end

  describe "reap_retained_desktops" do
    test "returns [] when container mode or retention is disabled" do
      assert ContainerRuntime.reap_retained_desktops(["MT-1"]) == []

      write_workflow_file!(Workflow.workflow_file_path(),
        container_enabled: true,
        container_keep_pr_desktops: false
      )

      assert ContainerRuntime.reap_retained_desktops(["MT-1"]) == []
    end

    test "reaps only inactive desktops whose PRs are merged or closed" do
      write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)
      test_pid = self()

      Application.put_env(:symphony_elixir, :pull_request_resolver, fn workspace ->
        cond do
          String.contains?(workspace, "MT-A") -> :merged
          String.contains?(workspace, "MT-C") -> :open
          true -> :none
        end
      end)

      Application.put_env(:symphony_elixir, :container_command_runner, fn engine, args ->
        send(test_pid, {:engine_cmd, engine, args})

        case args do
          ["ps" | _] -> {:ok, {"MT-A\nMT-B\nMT-C\n", 0}}
          ["rm" | _] -> {:ok, {"", 0}}
        end
      end)

      # MT-B is still active so it is never inspected; MT-C's PR is open so it is kept.
      assert ContainerRuntime.reap_retained_desktops(["MT-B"]) == ["MT-A"]
      assert_received {:engine_cmd, "docker", ["rm", "--force", "symphony-agent-MT-A"]}
      refute_received {:engine_cmd, "docker", ["rm", "--force", "symphony-agent-MT-C"]}
    end

    test "keeps a desktop whose workspace path cannot be resolved" do
      regular_file =
        Path.join(System.tmp_dir!(), "symphony-not-a-dir-#{System.unique_integer([:positive])}")

      File.write!(regular_file, "")
      on_exit(fn -> File.rm_rf(regular_file) end)

      write_workflow_file!(Workflow.workflow_file_path(),
        container_enabled: true,
        workspace_root: Path.join(regular_file, "nested")
      )

      Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, args ->
        case args do
          ["ps" | _] -> {:ok, {"MT-Z\n", 0}}
        end
      end)

      assert ContainerRuntime.reap_retained_desktops([]) == []
    end

    test "logs and returns [] when listing managed containers fails" do
      write_workflow_file!(Workflow.workflow_file_path(), container_enabled: true)

      Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, _args ->
        {:ok, {"boom", 1}}
      end)

      log = capture_log(fn -> assert ContainerRuntime.reap_retained_desktops([]) == [] end)
      assert log =~ "Failed to list managed agent containers"

      Application.put_env(:symphony_elixir, :container_command_runner, fn _engine, _args ->
        {:error, :engine_unreachable}
      end)

      log = capture_log(fn -> assert ContainerRuntime.reap_retained_desktops([]) == [] end)
      assert log =~ "Failed to list managed agent containers"
    end
  end
end
