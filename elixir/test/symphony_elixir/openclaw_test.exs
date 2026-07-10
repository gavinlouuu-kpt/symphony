defmodule SymphonyElixir.OpenClawTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.Config.Schema.OpenClaw
  alias SymphonyElixir.OpenClaw.Client, as: OpenClawClient
  alias SymphonyElixir.OpenClaw.Notifier, as: OpenClawNotifier

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeOpenClawClient do
    def send_message(message, settings) do
      if recipient = Application.get_env(:symphony_elixir, :openclaw_test_recipient) do
        send(recipient, {:openclaw_message, message, settings})
      end

      :ok
    end

    def create_thread(message, thread_name, settings) do
      if recipient = Application.get_env(:symphony_elixir, :openclaw_test_recipient) do
        send(recipient, {:openclaw_thread_created, message, thread_name, settings})
      end

      {:ok, %{thread_id: "thread-123", target: "channel:thread-123"}}
    end

    def reply_to_thread(message, thread_ref, settings) do
      if recipient = Application.get_env(:symphony_elixir, :openclaw_test_recipient) do
        send(recipient, {:openclaw_thread_reply, message, thread_ref, settings})
      end

      :ok
    end
  end

  defmodule FakeGithubIssueClient do
    def create_issue(title, body, labels) do
      if recipient = Application.get_env(:symphony_elixir, :openclaw_test_recipient) do
        send(recipient, {:github_issue_created, title, body, labels})
      end

      {:ok,
       %Issue{
         id: "github:owner/repo#123",
         identifier: "GH-123",
         title: title,
         description: body,
         state: "open",
         url: "https://github.com/owner/repo/issues/123",
         labels: labels
       }}
    end
  end

  setup do
    previous_client = Application.get_env(:symphony_elixir, :openclaw_client_module)
    previous_github_client = Application.get_env(:symphony_elixir, :github_client_module)
    previous_recipient = Application.get_env(:symphony_elixir, :openclaw_test_recipient)
    previous_async = Application.get_env(:symphony_elixir, :openclaw_notify_async)
    previous_registry_file = Application.get_env(:symphony_elixir, :openclaw_thread_registry_file)
    previous_endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    registry_root = Path.join(System.tmp_dir!(), "symphony-openclaw-registry-#{System.unique_integer([:positive])}")
    registry_file = Path.join(registry_root, "threads.json")

    on_exit(fn ->
      restore_app_env(:openclaw_client_module, previous_client)
      restore_app_env(:github_client_module, previous_github_client)
      restore_app_env(:openclaw_test_recipient, previous_recipient)
      restore_app_env(:openclaw_notify_async, previous_async)
      restore_app_env(:openclaw_thread_registry_file, previous_registry_file)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint_config)
      File.rm_rf(registry_root)
    end)

    Application.put_env(:symphony_elixir, :openclaw_notify_async, false)
    Application.put_env(:symphony_elixir, :openclaw_thread_registry_file, registry_file)
    OpenClawNotifier.reset_issue_threads_for_test()
    :ok
  end

  test "config supports OpenClaw channel bridge settings" do
    previous_target = System.get_env("SYMPHONY_TEST_OPENCLAW_TARGET")

    on_exit(fn ->
      restore_env("SYMPHONY_TEST_OPENCLAW_TARGET", previous_target)
    end)

    System.put_env("SYMPHONY_TEST_OPENCLAW_TARGET", "channel:123")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "github-token",
      tracker_project_slug: "owner/repo",
      tracker_active_states: ["open"],
      tracker_terminal_states: ["closed"],
      openclaw_enabled: true,
      openclaw_command: "mise exec -- openclaw",
      openclaw_channel: "discord",
      openclaw_account: "ops",
      openclaw_target: "$SYMPHONY_TEST_OPENCLAW_TARGET",
      openclaw_timeout_ms: 5_000,
      openclaw_intake_enabled: true,
      openclaw_intake_token: "intake-token",
      openclaw_intake_labels: ["Symphony", ""],
      openclaw_events: ["ALL", "retry_scheduled", ""]
    )

    config = Config.settings!()

    assert config.openclaw.enabled == true
    assert config.openclaw.command == "mise exec -- openclaw"
    assert config.openclaw.channel == "discord"
    assert config.openclaw.account == "ops"
    assert config.openclaw.target == "channel:123"
    assert config.openclaw.timeout_ms == 5_000
    assert config.openclaw.intake_enabled == true
    assert config.openclaw.intake_token == "intake-token"
    assert config.openclaw.intake_labels == ["symphony"]
    assert config.openclaw.events == ["all", "retry_scheduled"]
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      openclaw_enabled: true,
      openclaw_target: nil
    )

    assert {:error, :missing_openclaw_target} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      openclaw_intake_enabled: true,
      openclaw_intake_token: "intake-token"
    )

    assert {:error, :openclaw_intake_requires_github_tracker} = Config.validate!()
  end

  test "client sends messages through OpenClaw CLI arguments" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-openclaw-client-#{System.unique_integer([:positive])}")

    fake_openclaw = Path.join(test_root, "fake-openclaw")
    trace_file = Path.join(test_root, "openclaw.trace")

    try do
      File.mkdir_p!(test_root)

      File.write!(fake_openclaw, """
      #!/bin/sh
      for arg in "$@"; do
        printf 'ARG:%s\\n' "$arg" >> "#{trace_file}"
      done
      """)

      File.chmod!(fake_openclaw, 0o755)

      settings = %OpenClaw{
        command: fake_openclaw,
        channel: "discord",
        account: "ops",
        target: "channel:123",
        timeout_ms: 1_000
      }

      assert :ok = OpenClawClient.send_message("hello from symphony", settings)

      trace = File.read!(trace_file)
      assert trace =~ "ARG:message\n"
      assert trace =~ "ARG:send\n"
      assert trace =~ "ARG:--channel\n"
      assert trace =~ "ARG:discord\n"
      assert trace =~ "ARG:--account\n"
      assert trace =~ "ARG:ops\n"
      assert trace =~ "ARG:--target\n"
      assert trace =~ "ARG:channel:123\n"
      assert trace =~ "ARG:--message\n"
      assert trace =~ "ARG:hello from symphony\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "client creates OpenClaw message threads and extracts thread target" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-openclaw-thread-#{System.unique_integer([:positive])}")

    fake_openclaw = Path.join(test_root, "fake-openclaw")
    trace_file = Path.join(test_root, "openclaw.trace")

    try do
      File.mkdir_p!(test_root)

      File.write!(fake_openclaw, """
      #!/bin/sh
      for arg in "$@"; do
        printf 'ARG:%s\\n' "$arg" >> "#{trace_file}"
      done
      cat <<'JSON'
      [state-migrations] warning before json
      {
        "ok": true,
        "thread": {
          "id": "999",
          "name": "GH-999 Routed issue"
        }
      }
      JSON
      """)

      File.chmod!(fake_openclaw, 0o755)

      settings = %OpenClaw{
        command: fake_openclaw,
        channel: "discord",
        account: "ops",
        target: "channel:123",
        timeout_ms: 1_000
      }

      assert {:ok, %{thread_id: "999", target: "channel:999"}} =
               OpenClawClient.create_thread("dispatch details", "GH-999 Routed issue", settings)

      trace = File.read!(trace_file)
      assert trace =~ "ARG:message\n"
      assert trace =~ "ARG:thread\n"
      assert trace =~ "ARG:create\n"
      assert trace =~ "ARG:--channel\n"
      assert trace =~ "ARG:discord\n"
      assert trace =~ "ARG:--account\n"
      assert trace =~ "ARG:ops\n"
      assert trace =~ "ARG:--target\n"
      assert trace =~ "ARG:channel:123\n"
      assert trace =~ "ARG:--thread-name\n"
      assert trace =~ "ARG:GH-999 Routed issue\n"
      assert trace =~ "ARG:--message\n"
      assert trace =~ "ARG:dispatch details\n"
      assert trace =~ "ARG:--json\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "client replies to OpenClaw message threads" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-openclaw-thread-reply-#{System.unique_integer([:positive])}")

    fake_openclaw = Path.join(test_root, "fake-openclaw")
    trace_file = Path.join(test_root, "openclaw.trace")

    try do
      File.mkdir_p!(test_root)

      File.write!(fake_openclaw, """
      #!/bin/sh
      for arg in "$@"; do
        printf 'ARG:%s\\n' "$arg" >> "#{trace_file}"
      done
      """)

      File.chmod!(fake_openclaw, 0o755)

      settings = %OpenClaw{
        command: fake_openclaw,
        channel: "discord",
        account: "ops",
        target: "channel:123",
        timeout_ms: 1_000
      }

      assert :ok =
               OpenClawClient.reply_to_thread(
                 "implementation update",
                 %{thread_id: "999", target: "channel:999"},
                 settings
               )

      trace = File.read!(trace_file)
      assert trace =~ "ARG:message\n"
      assert trace =~ "ARG:send\n"
      refute trace =~ "ARG:thread\n"
      refute trace =~ "ARG:reply\n"
      assert trace =~ "ARG:--channel\n"
      assert trace =~ "ARG:discord\n"
      assert trace =~ "ARG:--account\n"
      assert trace =~ "ARG:ops\n"
      assert trace =~ "ARG:--target\n"
      assert trace =~ "ARG:channel:999\n"
      assert trace =~ "ARG:--message\n"
      assert trace =~ "ARG:implementation update\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "notifier formats blocked issue messages for OpenClaw" do
    Application.put_env(:symphony_elixir, :openclaw_client_module, FakeOpenClawClient)
    Application.put_env(:symphony_elixir, :openclaw_test_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      openclaw_enabled: true,
      openclaw_target: "channel:123",
      openclaw_events: ["issue_blocked"]
    )

    OpenClawNotifier.publish(:issue_blocked, %{
      issue_id: "issue-openclaw-blocked",
      issue: %Issue{
        id: "issue-openclaw-blocked",
        identifier: "MT-OPENCLAW",
        title: "Needs operator input",
        state: "In Progress",
        url: "https://example.invalid/issues/MT-OPENCLAW"
      },
      error: "codex turn requires operator input",
      session_id: "session-openclaw",
      sandbox: %{novnc_url: "http://127.0.0.1:16901"}
    })

    assert_receive {:openclaw_message, message, settings}
    assert settings.channel == "discord"
    assert settings.target == "channel:123"
    assert message =~ "Symphony issue blocked"
    assert message =~ "Issue: MT-OPENCLAW"
    assert message =~ "Reason: codex turn requires operator input"
    assert message =~ "noVNC: http://127.0.0.1:16901"
  end

  test "notifier creates a dispatch thread and routes issue updates into it" do
    Application.put_env(:symphony_elixir, :openclaw_client_module, FakeOpenClawClient)
    Application.put_env(:symphony_elixir, :openclaw_test_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      openclaw_enabled: true,
      openclaw_target: "channel:123",
      openclaw_events: ["dispatch_started", "role_agent_completed", "agent_completed"]
    )

    issue = %Issue{
      id: "github:owner/repo#456",
      identifier: "GH-456",
      title: "Route updates into a Discord issue thread",
      state: "open",
      url: "https://github.com/owner/repo/issues/456"
    }

    OpenClawNotifier.publish(:dispatch_started, %{
      issue: issue,
      attempt: 0,
      worker_host: "worker-a"
    })

    assert_receive {:openclaw_thread_created, dispatch_message, thread_name, settings}
    assert settings.target == "channel:123"
    assert thread_name == "GH-456 Route updates into a Discord issue thread"
    assert dispatch_message =~ "Symphony issue dispatched"
    assert dispatch_message =~ "Issue: GH-456"
    assert dispatch_message =~ "Worker: worker-a"
    assert dispatch_message =~ "Use this thread for status and implementation discussion."
    assert dispatch_message =~ "Keep the project channel clear for new issue intake."
    assert File.read!(Application.fetch_env!(:symphony_elixir, :openclaw_thread_registry_file)) =~ "channel:thread-123"

    OpenClawNotifier.publish(:role_agent_completed, %{
      issue: issue,
      issue_id: issue.id,
      identifier: issue.identifier,
      role: "evaluator",
      cycle: 2,
      max_cycles: 5,
      session_id: "session-role",
      workspace_path: "/workspaces/GH-456",
      evidence_summary:
        "Evidence: evaluator handoff evidence review (status 0)\nEvidence command: cat .symphony/artifacts/handoff-evidence.md\nEvidence artifacts: .symphony/artifacts/handoff-evidence.md exists\nEvidence recorded: 2026-07-10T04:00:00Z"
    })

    assert_receive {:openclaw_thread_reply, role_message, role_thread_ref, role_settings}
    assert role_settings.target == "channel:123"
    assert role_thread_ref.target == "channel:thread-123"
    assert role_message =~ "Symphony role agent completed"
    assert role_message =~ "Issue: GH-456"
    assert role_message =~ "Role: evaluator"
    assert role_message =~ "Cycle: 2/5"
    assert role_message =~ "Session: session-role"
    assert role_message =~ "Evidence: evaluator handoff evidence review (status 0)"
    assert role_message =~ "Evidence artifacts: .symphony/artifacts/handoff-evidence.md exists"

    OpenClawNotifier.publish(:agent_completed, %{
      issue: issue,
      issue_id: issue.id,
      identifier: issue.identifier,
      session_id: "session-threaded"
    })

    assert_receive {:openclaw_thread_reply, update_message, thread_ref, update_settings}
    assert update_settings.target == "channel:123"
    assert thread_ref.target == "channel:thread-123"
    assert update_message =~ "Symphony agent completed"
    assert update_message =~ "Issue: GH-456"
    assert update_message =~ "Session: session-threaded"
    refute_receive {:openclaw_message, _, _}, 100
  end

  test "notifier suppresses duplicate initial dispatch when issue thread already exists" do
    Application.put_env(:symphony_elixir, :openclaw_client_module, FakeOpenClawClient)
    Application.put_env(:symphony_elixir, :openclaw_test_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      openclaw_enabled: true,
      openclaw_target: "channel:123",
      openclaw_events: ["dispatch_started"]
    )

    issue = %Issue{
      id: "github:owner/repo#456",
      identifier: "GH-456",
      title: "Route updates into a Discord issue thread",
      state: "open",
      url: "https://github.com/owner/repo/issues/456"
    }

    OpenClawNotifier.publish(:dispatch_started, %{
      issue: issue,
      attempt: 0,
      worker_host: "worker-a"
    })

    assert_receive {:openclaw_thread_created, _, _, _}

    OpenClawNotifier.publish(:dispatch_started, %{
      issue: issue,
      attempt: 0,
      worker_host: "worker-a"
    })

    refute_receive {:openclaw_thread_created, _, _, _}, 100
    refute_receive {:openclaw_thread_reply, _, _, _}, 100
    refute_receive {:openclaw_message, _, _}, 100
  end

  test "notifier routes non-initial redispatch into existing issue thread" do
    Application.put_env(:symphony_elixir, :openclaw_client_module, FakeOpenClawClient)
    Application.put_env(:symphony_elixir, :openclaw_test_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      openclaw_enabled: true,
      openclaw_target: "channel:123",
      openclaw_events: ["dispatch_started"]
    )

    issue = %Issue{
      id: "github:owner/repo#456",
      identifier: "GH-456",
      title: "Route updates into a Discord issue thread",
      state: "open",
      url: "https://github.com/owner/repo/issues/456"
    }

    OpenClawNotifier.publish(:dispatch_started, %{
      issue: issue,
      attempt: 0,
      worker_host: "worker-a"
    })

    assert_receive {:openclaw_thread_created, _, _, _}

    OpenClawNotifier.publish(:dispatch_started, %{
      issue: issue,
      attempt: 2,
      worker_host: "worker-a"
    })

    assert_receive {:openclaw_thread_reply, retry_message, thread_ref, _settings}
    assert thread_ref.target == "channel:thread-123"
    assert retry_message =~ "Attempt: 2"
    refute_receive {:openclaw_message, _, _}, 100
  end

  test "orchestrator publishes blocked agent events through OpenClaw" do
    Application.put_env(:symphony_elixir, :openclaw_client_module, FakeOpenClawClient)
    Application.put_env(:symphony_elixir, :openclaw_test_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      openclaw_enabled: true,
      openclaw_target: "channel:123",
      openclaw_events: ["issue_blocked"]
    )

    orchestrator_name = Module.concat(__MODULE__, BlockedOpenClawOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    try do
      issue_id = "issue-openclaw-orchestrator"
      ref = make_ref()

      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "MT-OPENCLAW-ORCH",
        issue: %Issue{
          id: issue_id,
          identifier: "MT-OPENCLAW-ORCH",
          title: "Blocked orchestration",
          state: "In Progress",
          url: "https://example.invalid/issues/MT-OPENCLAW-ORCH"
        },
        worker_host: nil,
        workspace_path: nil,
        sandbox: %{api_url: "http://127.0.0.1:18001"},
        session_id: "session-openclaw-orch",
        last_codex_event: :turn_input_required,
        last_codex_timestamp: DateTime.utc_now(),
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn state ->
        %{
          state
          | running: %{issue_id => running_entry},
            claimed: MapSet.new([issue_id]),
            retry_attempts: %{}
        }
      end)

      send(pid, {:DOWN, ref, :process, self(), :normal})

      assert_receive {:openclaw_message, message, _settings}
      assert message =~ "Symphony issue blocked"
      assert message =~ "Issue: MT-OPENCLAW-ORCH"
      assert message =~ "Reason: codex turn requires operator input"
      assert message =~ "API: http://127.0.0.1:18001"
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  test "OpenClaw intake endpoint creates GitHub issues for the configured profile" do
    start_test_endpoint([])
    Application.put_env(:symphony_elixir, :github_client_module, FakeGithubIssueClient)
    Application.put_env(:symphony_elixir, :openclaw_test_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "github-token",
      tracker_project_slug: "owner/repo",
      tracker_required_labels: ["symphony"],
      tracker_active_states: ["open"],
      tracker_terminal_states: ["closed"],
      openclaw_intake_enabled: true,
      openclaw_intake_token: "intake-token",
      openclaw_intake_labels: ["from-openclaw"]
    )

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer intake-token")
      |> post("/api/v1/openclaw/issues", %{
        "text" => """
        issue Add profile-routed OpenClaw intake

        Create a GitHub issue from a Discord message and let Symphony pick it up.
        """,
        "source" => %{
          "channel" => "discord",
          "channel_id" => "1234567890",
          "message_id" => "555",
          "sender" => "gavin"
        }
      })

    assert %{
             "ok" => true,
             "message" => message,
             "issue" => %{
               "identifier" => "GH-123",
               "title" => "Add profile-routed OpenClaw intake",
               "url" => "https://github.com/owner/repo/issues/123"
             }
           } = json_response(conn, 201)

    assert message =~ "Created GitHub issue GH-123"

    assert_receive {:github_issue_created, title, body, labels}
    assert title == "Add profile-routed OpenClaw intake"
    assert body =~ "Create a GitHub issue from a Discord message"
    assert body =~ "## OpenClaw Orchestration"
    assert body =~ "independent Planner -> Generator -> Evaluator agents"
    assert body =~ "Planner: read the current project `AGENTS.md`"
    assert body =~ "Evaluator: independently review the result"
    assert body =~ "A single agent writing three sections does not satisfy this contract"
    assert body =~ "active routing label, usually `openclaw-intake`"
    assert body =~ "Leave the GitHub issue open for normal review handoff"
    assert body =~ "OpenClaw intake:"
    assert body =~ "channel_id: 1234567890"
    assert body =~ "sender: gavin"
    assert labels == ["symphony", "from-openclaw"]
  end

  test "OpenClaw intake endpoint rejects missing bearer tokens" do
    start_test_endpoint([])
    Application.put_env(:symphony_elixir, :github_client_module, FakeGithubIssueClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "github-token",
      tracker_project_slug: "owner/repo",
      tracker_active_states: ["open"],
      tracker_terminal_states: ["closed"],
      openclaw_intake_enabled: true,
      openclaw_intake_token: "intake-token"
    )

    conn = post(build_conn(), "/api/v1/openclaw/issues", %{"text" => "issue Missing auth"})

    assert %{"ok" => false, "error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
