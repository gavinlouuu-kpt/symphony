defmodule SymphonyElixir.CuaSandboxTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Cua.Sandbox
  alias SymphonyElixir.SSH

  test "config validation accepts only supported CUA worker settings" do
    write_workflow_file!(Workflow.workflow_file_path(), worker_provider: "cua")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), worker_provider: "bogus")
    assert {:error, {:unsupported_worker_provider, "bogus"}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      worker_provider: "cua",
      cua_driver: "cloud"
    )

    assert {:error, {:unsupported_cua_driver, "cloud"}} = Config.validate!()
  end

  test "ensure_for_issue launches a deterministic CUA docker sandbox" do
    test_root = Path.join(System.tmp_dir!(), "symphony-cua-launch-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "docker.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_executable!(test_root, "docker", trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"

    case "$*" in
      inspect*"symphony-mt-123"*)
        echo "Error: No such object: symphony-mt-123" >&2
        exit 1
        ;;
      run*)
        printf '%s\\n' 'container-123'
        exit 0
        ;;
      *)
        echo "unexpected docker call: $*" >&2
        exit 2
        ;;
    esac
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      worker_provider: "cua",
      cua_host: "127.0.0.2",
      cua_image: "local/symphony-cua-worker:test",
      cua_wait_for_ssh: false,
      cua_port_span: 10,
      cua_ssh_port_start: 31_000,
      cua_vnc_port_start: 32_000,
      cua_novnc_port_start: 33_000,
      cua_api_port_start: 34_000
    )

    issue = %Issue{id: "issue-123", identifier: "MT-123", title: "Launch CUA", state: "Todo"}

    assert {:ok, %{worker_host: worker_host, sandbox: sandbox}} = Sandbox.ensure_for_issue(issue)
    assert worker_host == sandbox.ssh_target
    assert sandbox.name == "symphony-mt-123"
    assert sandbox.provider == "cua"
    assert sandbox.driver == "docker"
    assert sandbox.host == "127.0.0.2"
    assert sandbox.lifecycle == "preserve"
    assert sandbox.novnc_url =~ "http://127.0.0.2:"
    assert sandbox.api_url =~ "http://127.0.0.2:"

    trace = File.read!(trace_file)
    assert trace =~ "inspect --format {{.State.Running}} symphony-mt-123"
    assert trace =~ "run -d --name symphony-mt-123"
    assert trace =~ "--label symphony.issue_id=issue-123"
    assert trace =~ "--label symphony.issue_identifier=MT-123"
    assert trace =~ "127.0.0.2:"
    assert trace =~ ":22"
    assert trace =~ ":5901"
    assert trace =~ ":6901"
    assert trace =~ ":8000"
    assert trace =~ "local/symphony-cua-worker:test"
  end

  test "ensure_for_issue reuses an existing CUA docker sandbox" do
    test_root = Path.join(System.tmp_dir!(), "symphony-cua-existing-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "docker.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_executable!(test_root, "docker", trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"

    case "$*" in
      inspect*"symphony-mt-existing"*)
        printf '%s\\n' 'true'
        exit 0
        ;;
      port*"22/tcp"*)
        printf '%s\\n' '127.0.0.1:22123'
        exit 0
        ;;
      port*"5901/tcp"*)
        printf '%s\\n' '127.0.0.1:16123'
        exit 0
        ;;
      port*"6901/tcp"*)
        printf '%s\\n' '127.0.0.1:17123'
        exit 0
        ;;
      port*"8000/tcp"*)
        printf '%s\\n' '127.0.0.1:18123'
        exit 0
        ;;
      *)
        echo "unexpected docker call: $*" >&2
        exit 2
        ;;
    esac
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      worker_provider: "cua",
      cua_image: "local/symphony-cua-worker:test"
    )

    assert {:ok, %{worker_host: "cua@127.0.0.1:22123", sandbox: sandbox}} =
             Sandbox.ensure_for_issue("MT-EXISTING")

    assert sandbox == %{
             name: "symphony-mt-existing",
             provider: "cua",
             driver: "docker",
             source: "docker",
             status: "running",
             host: "127.0.0.1",
             ssh_target: "cua@127.0.0.1:22123",
             ssh_port: 22123,
             lifecycle: "preserve",
             vnc_url: "vnc://127.0.0.1:16123",
             novnc_url: "http://127.0.0.1:17123/",
             api_url: "http://127.0.0.1:18123/"
           }

    trace = File.read!(trace_file)
    refute trace =~ "run -d"
  end

  test "delete_for_issue removes terminal CUA sandboxes only when enabled" do
    test_root = Path.join(System.tmp_dir!(), "symphony-cua-delete-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "docker.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_executable!(test_root, "docker", trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    exit 0
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      worker_provider: "cua",
      cua_delete_on_terminal: false
    )

    assert :ok = Sandbox.delete_for_issue("MT-KEEP")
    refute File.exists?(trace_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      worker_provider: "cua",
      cua_delete_on_terminal: true
    )

    assert :ok = Sandbox.delete_for_issue("MT-DELETE")
    assert File.read!(trace_file) =~ "rm -f symphony-mt-delete"
  end

  test "cua worker provider uses noninteractive ssh defaults" do
    test_root = Path.join(System.tmp_dir!(), "symphony-cua-ssh-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_executable!(test_root, "ssh", trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    exit 0
    """)

    write_workflow_file!(Workflow.workflow_file_path(), worker_provider: "cua")

    assert {:ok, {"", 0}} = SSH.run("cua@127.0.0.1:22123", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-o BatchMode=yes"
    assert trace =~ "-o StrictHostKeyChecking=no"
    assert trace =~ "-o UserKnownHostsFile=/dev/null"
    assert trace =~ "-o ConnectTimeout=5"
    assert trace =~ "-T -p 22123 cua@127.0.0.1 bash -lc"
  end

  defp install_fake_executable!(test_root, name, trace_file, script) do
    fake_bin_dir = Path.join(test_root, "bin")
    executable = Path.join(fake_bin_dir, name)

    File.mkdir_p!(fake_bin_dir)
    File.write!(executable, script)
    File.chmod!(executable, 0o755)
    File.rm(trace_file)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end
end
