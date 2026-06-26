defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{IssueIntake, Linear.Adapter}
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule IssueIntakeLinearClient do
    def graphql(query, variables) do
      test_pid = Application.fetch_env!(:symphony_elixir, :issue_intake_test_pid)
      results = Application.fetch_env!(:symphony_elixir, :issue_intake_test_results)
      send(test_pid, {:issue_intake_graphql, query, variables})

      Agent.get_and_update(results, fn
        [result | rest] -> {result, rest}
        [] -> {{:error, :unexpected_graphql}, []}
      end)
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end

    def handle_call({:review_console_message, request}, _from, state) do
      reply = Keyword.get(state, :console, %{role: "orchestrator", body: "console ok"})
      {:reply, {:ok, Map.put(reply, :request, request)}, state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert :ok = SymphonyElixir.Tracker.add_issue_label("issue-1", "Human Review")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}
    assert_receive {:memory_tracker_label_add, "issue-1", "Human Review"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")
    assert :ok = Memory.add_issue_label("issue-1", "quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "linear adapter creates and adds issue labels without replacing existing labels" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{
                 "id" => "team-1",
                 "labels" => %{"nodes" => []}
               }
             }
           }
         }},
        {:ok,
         %{
           "data" => %{
             "issueLabelCreate" => %{
               "success" => true,
               "issueLabel" => %{"id" => "label-human-review"}
             }
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.add_issue_label("issue-1", "symphony:human-review")

    assert_receive {:graphql_called, label_lookup_query, %{issueId: "issue-1", labelName: "symphony:human-review"}}
    assert label_lookup_query =~ "labels"

    assert_receive {:graphql_called, create_label_query, %{teamId: "team-1", labelName: "symphony:human-review"}}
    assert create_label_query =~ "issueLabelCreate"

    assert_receive {:graphql_called, add_label_query, %{issueId: "issue-1", labelId: "label-human-review"}}
    assert add_label_query =~ "addedLabelIds"
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1, "blocked" => 1},
             "project" => %{
               "tracker_kind" => "linear",
               "project_slug" => "project",
               "project_url" => "https://linear.app/project/project/issues",
               "workspace_root" => Config.settings!().workspace.root,
               "worker_provider" => "ssh",
               "cua_host" => "127.0.0.1",
               "dashboard_host" => "127.0.0.1"
             },
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "issue_url" => "https://example.org/issues/MT-HTTP",
                 "state" => "In Progress",
                 "phase" => "builder",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "sandbox" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "issue_url" => "https://example.org/issues/MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "phase" => "builder",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "sandbox" => nil
               }
             ],
             "blocked" => [
               %{
                 "issue_id" => "issue-blocked",
                 "issue_identifier" => "MT-BLOCKED",
                 "issue_url" => "https://example.org/issues/MT-BLOCKED",
                 "state" => "In Progress",
                 "error" => "codex turn requires operator input",
                 "phase" => "builder",
                 "worker_host" => "dm-dev2",
                 "workspace_path" => "/workspaces/MT-BLOCKED",
                 "sandbox" => %{
                   "name" => "symphony-mt-blocked",
                   "provider" => "cua",
                   "driver" => "docker",
                   "source" => "docker",
                   "status" => "running",
                   "host" => "127.0.0.1",
                   "ssh_target" => "cua@127.0.0.1:22123",
                   "ssh_port" => 22123,
                   "lifecycle" => "delete_on_terminal",
                   "vnc_url" => "vnc://127.0.0.1:16123",
                   "novnc_url" => "http://127.0.0.1:17123/",
                   "api_url" => "http://127.0.0.1:18123/"
                 },
                 "session_id" => "thread-blocked",
                 "blocked_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("blocked_at"),
                 "last_event" => "turn_input_required",
                 "last_message" => "turn blocked: waiting for user input",
                 "last_event_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("last_event_at")
               }
             ],
             "sandboxes" => [
               %{
                 "issue_id" => "issue-blocked",
                 "issue_identifier" => "MT-BLOCKED",
                 "issue_url" => "https://example.org/issues/MT-BLOCKED",
                 "issue_status" => "blocked",
                 "worker_host" => "dm-dev2",
                 "workspace_path" => "/workspaces/MT-BLOCKED",
                 "sandbox" => %{
                   "name" => "symphony-mt-blocked",
                   "provider" => "cua",
                   "driver" => "docker",
                   "source" => "docker",
                   "status" => "running",
                   "host" => "127.0.0.1",
                   "ssh_target" => "cua@127.0.0.1:22123",
                   "ssh_port" => 22123,
                   "lifecycle" => "delete_on_terminal",
                   "vnc_url" => "vnc://127.0.0.1:16123",
                   "novnc_url" => "http://127.0.0.1:17123/",
                   "api_url" => "http://127.0.0.1:18123/"
                 }
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "sandbox" => nil,
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "sandbox" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "phase" => "builder",
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "blocked" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-BLOCKED")

    assert %{
             "status" => "blocked",
             "last_error" => "codex turn requires operator input",
             "blocked" => %{
               "session_id" => "thread-blocked",
               "state" => "In Progress",
               "error" => "codex turn requires operator input"
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)

    conn =
      post(build_conn(), "/api/v1/console", %{
        "target" => "reviewer",
        "issue_identifier" => "MT-HTTP",
        "body" => "review this"
      })

    assert %{
             "role" => "orchestrator",
             "body" => "console ok",
             "request" => %{
               "target" => "reviewer",
               "issue_identifier" => "MT-HTTP",
               "body" => "review this"
             }
           } = json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/console"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }

    assert json_response(post(build_conn(), "/api/v1/console", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ ~r|/dashboard\.css\?v=[0-9a-f]{12}|

    assert html =~
             ~r|<link rel="icon" type="image/png" sizes="128x128" href="/favicon\.png\?v=[0-9a-f]{12}">|

    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ "text-decoration-thickness: 1px"

    favicon_conn = get(build_conn(), "/favicon.png")
    assert response(favicon_conn, 200) == File.read!("priv/static/favicon.png")
    assert Plug.Conn.get_resp_header(favicon_conn, "content-type") == ["image/png; charset=utf-8"]

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "project Dashboard"
    assert html =~ "Workspace root"
    assert html =~ "https://linear.app/project/project/issues"
    assert html =~ "Review console"
    assert html =~ "Private issue-scoped messages"
    assert html =~ "Create issue"
    assert html =~ ~s(href="/issues/new")
    assert html =~ "Orchestrator"
    assert html =~ "Reviewer"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "MT-BLOCKED"
    assert html =~ ~s(href="https://example.org/issues/MT-HTTP")
    assert html =~ ~s(href="https://example.org/issues/MT-RETRY")
    assert html =~ ~s(href="https://example.org/issues/MT-BLOCKED")
    assert html =~ ~s(aria-label="Open MT-HTTP in the issue tracker")
    assert html =~ "rendered"
    assert html =~ "turn blocked: waiting for user input"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    assert html =~ "CUA sandboxes"
    assert html =~ "symphony-mt-blocked"
    assert html =~ "Open noVNC"
    assert html =~ "closes when terminal"
    assert html =~ "cua@127.0.0.1:22123"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "javascript:alert('nope')",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)

    refute render(view) =~ "javascript:alert"
  end

  test "issue creator liveview renders project context and intake controls" do
    orchestrator_name = Module.concat(__MODULE__, :IssueCreatorOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/issues/new")

    assert html =~ "Issue Creator"
    assert html =~ "Scan and Draft"
    assert html =~ "New request"
    assert html =~ "project"
    assert html =~ ~s(href="/")
  end

  test "issue intake creates a Linear issue from the reviewed draft" do
    ensure_issue_intake_running()
    previous_state = :sys.get_state(IssueIntake)
    previous_results = Application.get_env(:symphony_elixir, :issue_intake_test_results)
    previous_test_pid = Application.get_env(:symphony_elixir, :issue_intake_test_pid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, results} =
      Agent.start_link(fn ->
        [
          {:ok,
           %{
             "data" => %{
               "projects" => %{
                 "nodes" => [
                   %{
                     "id" => "project-1",
                     "name" => "Project",
                     "teams" => %{
                       "nodes" => [
                         %{
                           "id" => "team-1",
                           "key" => "KIN",
                           "states" => %{
                             "nodes" => [
                               %{"id" => "state-todo", "name" => "Todo"},
                               %{"id" => "state-review", "name" => "In Review"}
                             ]
                           }
                         }
                       ]
                     }
                   }
                 ]
               }
             }
           }},
          {:ok,
           %{
             "data" => %{
               "issueCreate" => %{
                 "success" => true,
                 "issue" => %{
                   "id" => "issue-101",
                   "identifier" => "KIN-101",
                   "title" => "Add intake workflow",
                   "url" => "https://linear.app/kingsphase/issue/KIN-101/add-intake-workflow",
                   "state" => %{"name" => "Todo"}
                 }
               }
             }
           }}
        ]
      end)

    Application.put_env(:symphony_elixir, :linear_client_module, IssueIntakeLinearClient)
    Application.put_env(:symphony_elixir, :issue_intake_test_results, results)
    Application.put_env(:symphony_elixir, :issue_intake_test_pid, self())

    on_exit(fn ->
      :sys.replace_state(IssueIntake, fn _state -> previous_state end)

      if is_nil(previous_results) do
        Application.delete_env(:symphony_elixir, :issue_intake_test_results)
      else
        Application.put_env(:symphony_elixir, :issue_intake_test_results, previous_results)
      end

      if is_nil(previous_test_pid) do
        Application.delete_env(:symphony_elixir, :issue_intake_test_pid)
      else
        Application.put_env(:symphony_elixir, :issue_intake_test_pid, previous_test_pid)
      end

      if Process.alive?(results), do: Agent.stop(results)
    end)

    session = %{
      id: 1,
      kind: "feature",
      title: "Add intake workflow",
      original_request: "Create a planning page.",
      status: "drafting",
      messages: [%{role: "user", body: "Create a planning page.", created_at: now}],
      scan: %{repo_url: "repo", branch: "main", file_count: 2, top_level: [], languages: [], important_files: [], test_hints: []},
      draft: "Reviewed task draft",
      created_issue: nil,
      created_at: now,
      updated_at: now
    }

    :sys.replace_state(IssueIntake, fn _state -> %IssueIntake{sessions: [session], next_id: 2} end)

    assert {:ok, updated} = IssueIntake.create_linear_issue(1)
    assert updated.created_issue.identifier == "KIN-101"
    assert updated.created_issue.state == "Todo"

    assert_receive {:issue_intake_graphql, project_query, %{projectSlug: "project"}}
    assert project_query =~ "SymphonyIssueIntakeProject"

    assert_receive {:issue_intake_graphql, create_query, create_variables}
    assert create_query =~ "SymphonyIssueIntakeCreateIssue"
    assert create_variables.title == "Add intake workflow"
    assert create_variables.description == "Reviewed task draft"
    assert create_variables.stateId == "state-todo"
  end

  test "review console answers retained sandbox questions with dashboard context" do
    orchestrator_name = Module.concat(__MODULE__, :RetainedConsoleOrchestrator)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: %{}, console: %{role: "reviewer", body: "Queued retained reviewer from dashboard"}})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = %{
      running: [],
      retrying: [],
      blocked: [],
      sandboxes: [
        %{
          issue_identifier: "KIN-94",
          issue_status: "human_review",
          workspace_path: "/home/cua/workspaces/KIN-94",
          sandbox: %{novnc_url: "http://100.81.210.49:17678/"},
          evidence: [
            %{kind: "video", filename: "KIN-94-visible-smoke.mp4"},
            %{kind: "log", filename: "KIN-94-visible-exec.log"}
          ]
        }
      ]
    }

    assert {"reviewer", reviewer_body} =
             SymphonyElixirWeb.DashboardLive.console_response_for_test(
               payload,
               "KIN-94",
               "reviewer",
               "what test has been done?"
             )

    assert reviewer_body =~ "Queued retained reviewer from dashboard"

    assert {"orchestrator", orchestrator_body} =
             SymphonyElixirWeb.DashboardLive.console_response_for_test(
               payload,
               "KIN-94",
               "orchestrator",
               "status"
             )

    assert orchestrator_body =~ "Workspace: /home/cua/workspaces/KIN-94"
    assert orchestrator_body =~ "noVNC: http://100.81.210.49:17678/"
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1, "blocked" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  test "phoenix observability api links and serves local evidence artifacts" do
    evidence_root = Path.join(System.tmp_dir!(), "symphony-evidence-#{System.unique_integer([:positive])}")
    previous_evidence_root = System.get_env("SYMPHONY_EVIDENCE_ROOT")
    File.mkdir_p!(evidence_root)
    File.write!(Path.join(evidence_root, "MT-BLOCKED-visible-smoke.mp4"), "video")
    File.write!(Path.join(evidence_root, "OTHER-visible-smoke.mp4"), "other")
    System.put_env("SYMPHONY_EVIDENCE_ROOT", evidence_root)

    on_exit(fn ->
      restore_env("SYMPHONY_EVIDENCE_ROOT", previous_evidence_root)
      File.rm_rf(evidence_root)
    end)

    orchestrator_name = Module.concat(__MODULE__, :EvidenceOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert [
             %{
               "filename" => "MT-BLOCKED-visible-smoke.mp4",
               "href" => "/evidence/MT-BLOCKED-visible-smoke.mp4",
               "kind" => "video",
               "size_bytes" => 5
             }
           ] = get_in(state_payload, ["sandboxes", Access.at(0), "evidence"])

    evidence_response = get(build_conn(), "/evidence/MT-BLOCKED-visible-smoke.mp4")
    assert response(evidence_response, 200) == "video"
    assert Plug.Conn.get_resp_header(evidence_response, "content-type") == ["video/mp4; charset=utf-8"]

    assert response(get(build_conn(), "/evidence/OTHER-visible-smoke.mp4"), 200) == "other"
    assert response(get(build_conn(), "/evidence/.."), 404) == "Not Found"
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "https://example.org/issues/MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          issue_url: "https://example.org/issues/MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          issue_url: "https://example.org/issues/MT-BLOCKED",
          state: "In Progress",
          error: "codex turn requires operator input",
          worker_host: "dm-dev2",
          workspace_path: "/workspaces/MT-BLOCKED",
          session_id: "thread-blocked",
          blocked_at: DateTime.utc_now(),
          last_codex_event: :turn_input_required,
          last_codex_message: %{
            event: :turn_input_required,
            message: %{"method" => "turn/input_required"},
            timestamp: DateTime.utc_now()
          },
          last_codex_timestamp: DateTime.utc_now(),
          sandbox: %{
            name: "symphony-mt-blocked",
            provider: "cua",
            driver: "docker",
            source: "docker",
            status: "running",
            host: "127.0.0.1",
            ssh_target: "cua@127.0.0.1:22123",
            ssh_port: 22123,
            lifecycle: "delete_on_terminal",
            vnc_url: "vnc://127.0.0.1:16123",
            novnc_url: "http://127.0.0.1:17123/",
            api_url: "http://127.0.0.1:18123/"
          }
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp ensure_issue_intake_running do
    if Process.whereis(IssueIntake) do
      :ok
    else
      start_supervised!(IssueIntake)
      :ok
    end
  end
end
