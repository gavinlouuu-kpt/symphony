defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_required_labels: [],
          tracker_human_review_label: "symphony:human-review",
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_provider: "ssh",
          worker_ssh_hosts: [],
          worker_ssh_options: [],
          worker_max_concurrent_agents_per_host: nil,
          cua_driver: "docker",
          cua_executable: "docker",
          cua_host: "127.0.0.1",
          cua_image: "symphony-cua-worker:latest",
          cua_name_prefix: "symphony",
          cua_ssh_user: "cua",
          cua_ssh_authorized_key_path: nil,
          cua_codex_auth_path: nil,
          cua_codex_config_path: nil,
          cua_delete_on_terminal: false,
          cua_wait_for_ssh: true,
          cua_launch_timeout_ms: 120_000,
          cua_port_span: 1_000,
          cua_ssh_port_start: 22_000,
          cua_vnc_port_start: 15_900,
          cua_novnc_port_start: 16_900,
          cua_api_port_start: 18_000,
          cua_gpu: "none",
          cua_env: %{},
          cua_volumes: [],
          cua_docker_args: [],
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          container_enabled: nil,
          container_engine: nil,
          container_image: nil,
          container_name_prefix: nil,
          container_workspace_mount: nil,
          container_novnc_container_port: nil,
          container_novnc_host: nil,
          container_novnc_advertise_host: nil,
          container_codex_auth_file: nil,
          container_codex_auth_container_path: nil,
          container_extra_run_args: nil,
          container_features: nil,
          container_keep_pr_desktops: nil,
          container_record: nil,
          container_recordings_dir: nil,
          container_record_framerate: nil,
          container_record_segment_seconds: nil,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_required_labels = Keyword.get(config, :tracker_required_labels)
    tracker_human_review_label = Keyword.get(config, :tracker_human_review_label)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_provider = Keyword.get(config, :worker_provider)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_ssh_options = Keyword.get(config, :worker_ssh_options)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    cua_driver = Keyword.get(config, :cua_driver)
    cua_executable = Keyword.get(config, :cua_executable)
    cua_host = Keyword.get(config, :cua_host)
    cua_image = Keyword.get(config, :cua_image)
    cua_name_prefix = Keyword.get(config, :cua_name_prefix)
    cua_ssh_user = Keyword.get(config, :cua_ssh_user)
    cua_ssh_authorized_key_path = Keyword.get(config, :cua_ssh_authorized_key_path)
    cua_codex_auth_path = Keyword.get(config, :cua_codex_auth_path)
    cua_codex_config_path = Keyword.get(config, :cua_codex_config_path)
    cua_delete_on_terminal = Keyword.get(config, :cua_delete_on_terminal)
    cua_wait_for_ssh = Keyword.get(config, :cua_wait_for_ssh)
    cua_launch_timeout_ms = Keyword.get(config, :cua_launch_timeout_ms)
    cua_port_span = Keyword.get(config, :cua_port_span)
    cua_ssh_port_start = Keyword.get(config, :cua_ssh_port_start)
    cua_vnc_port_start = Keyword.get(config, :cua_vnc_port_start)
    cua_novnc_port_start = Keyword.get(config, :cua_novnc_port_start)
    cua_api_port_start = Keyword.get(config, :cua_api_port_start)
    cua_gpu = Keyword.get(config, :cua_gpu)
    cua_env = Keyword.get(config, :cua_env)
    cua_volumes = Keyword.get(config, :cua_volumes)
    cua_docker_args = Keyword.get(config, :cua_docker_args)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)

    container_settings =
      Keyword.take(config, [
        :container_enabled,
        :container_engine,
        :container_image,
        :container_name_prefix,
        :container_workspace_mount,
        :container_novnc_container_port,
        :container_novnc_host,
        :container_novnc_advertise_host,
        :container_codex_auth_file,
        :container_codex_auth_container_path,
        :container_extra_run_args,
        :container_features,
        :container_keep_pr_desktops,
        :container_record,
        :container_recordings_dir,
        :container_record_framerate,
        :container_record_segment_seconds
      ])

    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  required_labels: #{yaml_value(tracker_required_labels)}",
        "  human_review_label: #{yaml_value(tracker_human_review_label)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_provider, worker_ssh_hosts, worker_ssh_options, worker_max_concurrent_agents_per_host),
        cua_yaml(
          cua_driver,
          cua_executable,
          cua_host,
          cua_image,
          cua_name_prefix,
          cua_ssh_user,
          cua_ssh_authorized_key_path,
          cua_codex_auth_path,
          cua_codex_config_path,
          cua_delete_on_terminal,
          cua_wait_for_ssh,
          cua_launch_timeout_ms,
          cua_port_span,
          cua_ssh_port_start,
          cua_vnc_port_start,
          cua_novnc_port_start,
          cua_api_port_start,
          cua_gpu,
          cua_env,
          cua_volumes,
          cua_docker_args
        ),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        container_yaml(container_settings),
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp container_yaml(container_settings) do
    entries =
      container_settings
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map(fn {key, value} ->
        field = key |> Atom.to_string() |> String.replace_prefix("container_", "")
        "  #{field}: #{yaml_value(value)}"
      end)

    case entries do
      [] -> nil
      entries -> Enum.join(["container:" | entries], "\n")
    end
  end

  defp worker_yaml(provider, ssh_hosts, ssh_options, max_concurrent_agents_per_host)
       when provider in [nil, "ssh"] and ssh_hosts in [nil, []] and ssh_options in [nil, []] and
              is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(provider, ssh_hosts, ssh_options, max_concurrent_agents_per_host) do
    [
      "worker:",
      provider && "  provider: #{yaml_value(provider)}",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      ssh_options not in [nil, []] && "  ssh_options: #{yaml_value(ssh_options)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp cua_yaml(
         "docker",
         "docker",
         "127.0.0.1",
         "symphony-cua-worker:latest",
         "symphony",
         "cua",
         nil,
         nil,
         nil,
         false,
         true,
         120_000,
         1_000,
         22_000,
         15_900,
         16_900,
         18_000,
         "none",
         env,
         volumes,
         docker_args
       )
       when env in [nil, %{}] and volumes in [nil, []] and docker_args in [nil, []],
       do: nil

  defp cua_yaml(
         driver,
         executable,
         host,
         image,
         name_prefix,
         ssh_user,
         ssh_authorized_key_path,
         codex_auth_path,
         codex_config_path,
         delete_on_terminal,
         wait_for_ssh,
         launch_timeout_ms,
         port_span,
         ssh_port_start,
         vnc_port_start,
         novnc_port_start,
         api_port_start,
         gpu,
         env,
         volumes,
         docker_args
       ) do
    [
      "cua:",
      "  driver: #{yaml_value(driver)}",
      "  executable: #{yaml_value(executable)}",
      "  host: #{yaml_value(host)}",
      "  image: #{yaml_value(image)}",
      "  name_prefix: #{yaml_value(name_prefix)}",
      "  ssh_user: #{yaml_value(ssh_user)}",
      "  ssh_authorized_key_path: #{yaml_value(ssh_authorized_key_path)}",
      "  codex_auth_path: #{yaml_value(codex_auth_path)}",
      "  codex_config_path: #{yaml_value(codex_config_path)}",
      "  delete_on_terminal: #{yaml_value(delete_on_terminal)}",
      "  wait_for_ssh: #{yaml_value(wait_for_ssh)}",
      "  launch_timeout_ms: #{yaml_value(launch_timeout_ms)}",
      "  port_span: #{yaml_value(port_span)}",
      "  ssh_port_start: #{yaml_value(ssh_port_start)}",
      "  vnc_port_start: #{yaml_value(vnc_port_start)}",
      "  novnc_port_start: #{yaml_value(novnc_port_start)}",
      "  api_port_start: #{yaml_value(api_port_start)}",
      "  gpu: #{yaml_value(gpu)}",
      "  env: #{yaml_value(env || %{})}",
      "  volumes: #{yaml_value(volumes || [])}",
      "  docker_args: #{yaml_value(docker_args || [])}"
    ]
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
