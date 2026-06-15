defmodule SymphonyElixir.ContainerRuntime do
  @moduledoc """
  Manages one desktop-enabled container per issue so agents run isolated from
  the host and operators can watch (and drive) each agent's virtual desktop
  from the web dashboard via noVNC.
  """

  require Logger
  alias SymphonyElixir.{Config, PullRequest, Tailscale, Workspace}

  @issue_label "symphony.issue"

  @type container_info :: %{
          container_id: String.t(),
          container_name: String.t(),
          image: String.t(),
          engine: String.t(),
          workspace_mount: String.t(),
          novnc_port: pos_integer(),
          novnc_url: String.t(),
          recording: boolean(),
          recordings_path: String.t() | nil
        }

  @spec enabled?() :: boolean()
  def enabled? do
    case Config.settings() do
      {:ok, settings} -> settings.container.enabled
      {:error, _reason} -> false
    end
  end

  @doc """
  Starts (or reuses) the per-issue desktop container and returns connection
  info, including the host-published noVNC URL for the dashboard.
  """
  @spec ensure_started(String.t(), Path.t()) :: {:ok, container_info()} | {:error, term()}
  def ensure_started(issue_identifier, workspace)
      when is_binary(issue_identifier) and is_binary(workspace) do
    settings = Config.settings!().container
    name = container_name(issue_identifier, settings)

    with {:ok, bind_host} <- resolve_bind_host(settings),
         {:ok, advertise_host} <- resolve_advertise_host(settings, bind_host),
         {:ok, container_id} <- start_or_reuse(name, issue_identifier, workspace, settings, bind_host),
         {:ok, novnc_port} <- resolve_novnc_port(name, settings) do
      {:ok,
       %{
         container_id: container_id,
         container_name: name,
         image: settings.image,
         engine: settings.engine,
         workspace_mount: settings.workspace_mount,
         novnc_port: novnc_port,
         novnc_url: novnc_url(advertise_host, novnc_port),
         recording: settings.record,
         recordings_path: host_recordings_path(workspace, settings)
       }}
    end
  end

  # Where the in-container recordings land on the host. Recordings are written
  # under the bind-mounted workspace so they outlive the container and can be
  # served back for review; an absolute recordings_dir lives only inside the
  # container, so there is no host path to advertise.
  defp host_recordings_path(_workspace, %{record: false}), do: nil
  defp host_recordings_path(_workspace, %{recordings_dir: "/" <> _absolute}), do: nil
  defp host_recordings_path(workspace, %{recordings_dir: recordings_dir}), do: Path.join(workspace, recordings_dir)

  # "tailscale" binds the published port to this node's Tailscale IPv4 so the
  # desktop is reachable from the tailnet but not from other networks.
  defp resolve_bind_host(%{novnc_host: "tailscale"}), do: Tailscale.ipv4()
  defp resolve_bind_host(%{novnc_host: host}), do: {:ok, host}

  defp resolve_advertise_host(%{novnc_advertise_host: "tailscale"}, _bind_host) do
    Tailscale.advertise_host()
  end

  defp resolve_advertise_host(%{novnc_advertise_host: host}, _bind_host)
       when is_binary(host) and host != "" do
    {:ok, host}
  end

  defp resolve_advertise_host(%{novnc_host: "tailscale"}, bind_host) do
    # Prefer the MagicDNS name in dashboard URLs; fall back to the bound IP.
    case Tailscale.advertise_host() do
      {:ok, host} -> {:ok, host}
      {:error, _reason} -> {:ok, bind_host}
    end
  end

  defp resolve_advertise_host(_settings, bind_host), do: {:ok, bind_host}

  @doc """
  Force-removes the per-issue container. Safe to call when no container exists.
  """
  @spec remove_for_issue(String.t()) :: :ok
  def remove_for_issue(issue_identifier) when is_binary(issue_identifier) do
    case Config.settings() do
      {:ok, %{container: %{enabled: true} = settings}} ->
        name = container_name(issue_identifier, settings)

        case engine_cmd(settings.engine, ["rm", "--force", name]) do
          {:ok, {_output, 0}} ->
            Logger.info("Removed agent container container_name=#{name} issue_identifier=#{issue_identifier}")
            :ok

          {:ok, {_output, _status}} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to remove agent container container_name=#{name} issue_identifier=#{issue_identifier} error=#{inspect(reason)}")
            :ok
        end

      _ ->
        :ok
    end
  end

  @doc """
  Runs `script` inside the issue's container via `<engine> exec ... bash -lc`.
  Used by the setup phase to provision reusable container features.
  """
  @spec engine_exec(String.t(), String.t()) :: {:ok, {String.t(), integer()}} | {:error, term()}
  def engine_exec(container_name, script) when is_binary(container_name) and is_binary(script) do
    settings = Config.settings!().container
    engine_cmd(settings.engine, ["exec", container_name, "bash", "-lc", script])
  end

  @doc """
  Review-phase cleanup for a finished issue. When container mode and
  `keep_pr_desktops` are enabled and the issue still has an open PR, the desktop
  container (and its workspace) are retained so reviewers can keep driving it;
  the reaper removes it once the PR is merged or closed. Otherwise the container
  is force-removed.

  Returns `:retained` when the desktop was kept (the caller should leave the
  workspace in place) or `:removed` otherwise.
  """
  @spec cleanup_for_issue(String.t()) :: :retained | :removed
  def cleanup_for_issue(issue_identifier), do: cleanup_for_issue(issue_identifier, nil)

  @spec cleanup_for_issue(String.t(), String.t() | nil) :: :retained | :removed
  def cleanup_for_issue(issue_identifier, nil) when is_binary(issue_identifier) do
    case Config.settings() do
      {:ok, %{container: %{enabled: true, keep_pr_desktops: true}}} ->
        retain_or_remove(issue_identifier)

      {:ok, %{container: %{enabled: true}}} ->
        remove_for_issue(issue_identifier)
        :removed

      _ ->
        :removed
    end
  end

  # Containers are only managed on the orchestrator host; SSH-worker issues keep
  # the existing remote cleanup path.
  def cleanup_for_issue(_issue_identifier, _worker_host), do: :removed

  defp retain_or_remove(issue_identifier) do
    case Workspace.issue_workspace_path(issue_identifier) do
      {:ok, workspace} ->
        if PullRequest.open?(PullRequest.status(workspace)) do
          Logger.info("Retaining agent desktop for open PR issue_identifier=#{issue_identifier} workspace=#{workspace}")
          :retained
        else
          remove_for_issue(issue_identifier)
          :removed
        end

      {:error, _reason} ->
        remove_for_issue(issue_identifier)
        :removed
    end
  end

  @doc """
  Reaps retained desktops. For every managed container whose issue is no longer
  in `active_identifiers`, checks the PR status and removes the container (and
  its workspace) once the PR is merged or closed. Returns the reaped identifiers.
  Safe to call when container mode is disabled.
  """
  @spec reap_retained_desktops([String.t()]) :: [String.t()]
  def reap_retained_desktops(active_identifiers) when is_list(active_identifiers) do
    case Config.settings() do
      {:ok, %{container: %{enabled: true, keep_pr_desktops: true} = settings}} ->
        active = MapSet.new(active_identifiers)

        settings
        |> managed_issue_identifiers()
        |> Enum.reject(&MapSet.member?(active, &1))
        |> Enum.filter(&reap_if_outdated/1)

      _ ->
        []
    end
  end

  defp reap_if_outdated(issue_identifier) do
    case Workspace.issue_workspace_path(issue_identifier) do
      {:ok, workspace} ->
        if PullRequest.outdated?(PullRequest.status(workspace)) do
          Logger.info("Reaping outdated agent desktop issue_identifier=#{issue_identifier} workspace=#{workspace}")
          remove_for_issue(issue_identifier)
          Workspace.remove_issue_workspaces(issue_identifier)
          true
        else
          false
        end

      {:error, _reason} ->
        false
    end
  end

  defp managed_issue_identifiers(settings) do
    case engine_cmd(settings.engine, [
           "ps",
           "--all",
           "--filter",
           "label=symphony.managed=true",
           "--format",
           "{{index .Labels \"#{@issue_label}\"}}"
         ]) do
      {:ok, {output, 0}} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      {:ok, {output, status}} ->
        Logger.warning("Failed to list managed agent containers status=#{status} output=#{inspect(output)}")
        []

      {:error, reason} ->
        Logger.warning("Failed to list managed agent containers error=#{inspect(reason)}")
        []
    end
  end

  @spec container_name(String.t()) :: String.t()
  def container_name(issue_identifier) when is_binary(issue_identifier) do
    container_name(issue_identifier, Config.settings!().container)
  end

  defp container_name(issue_identifier, settings) do
    settings.name_prefix <> safe_identifier(issue_identifier)
  end

  defp safe_identifier(identifier) do
    String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp start_or_reuse(name, issue_identifier, workspace, settings, bind_host) do
    case engine_cmd(settings.engine, ["inspect", "--format", "{{.Id}} {{.State.Running}}", name]) do
      {:ok, {output, 0}} ->
        case String.split(String.trim(output)) do
          [container_id, "true"] ->
            {:ok, container_id}

          _ ->
            replace_container(name, issue_identifier, workspace, settings, bind_host)
        end

      {:ok, {_output, _status}} ->
        run_container(name, issue_identifier, workspace, settings, bind_host)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_container(name, issue_identifier, workspace, settings, bind_host) do
    case engine_cmd(settings.engine, ["rm", "--force", name]) do
      {:ok, {_output, 0}} -> run_container(name, issue_identifier, workspace, settings, bind_host)
      {:ok, {output, status}} -> {:error, {:container_remove_failed, name, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_container(name, issue_identifier, workspace, settings, bind_host) do
    with {:ok, auth_source} <- resolve_codex_auth_file(settings),
         {:ok, container_id} <- engine_run(name, issue_identifier, workspace, settings, bind_host),
         :ok <- provision_codex_auth(name, settings, auth_source) do
      Logger.info("Started agent container container_name=#{name} issue_identifier=#{issue_identifier} image=#{settings.image} workspace=#{workspace}")

      {:ok, container_id}
    end
  end

  defp engine_run(name, issue_identifier, workspace, settings, bind_host) do
    args =
      [
        "run",
        "--detach",
        "--name",
        name,
        "--label",
        "symphony.managed=true",
        "--label",
        "#{@issue_label}=#{issue_identifier}",
        "--volume",
        "#{workspace}:#{settings.workspace_mount}",
        "--publish",
        "#{bind_host}::#{settings.novnc_container_port}"
      ] ++ recording_run_args(settings) ++ settings.extra_run_args ++ [settings.image]

    case engine_cmd(settings.engine, args) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, status}} -> {:error, {:container_start_failed, name, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provision_codex_auth(name, settings, auth_source) do
    case install_codex_auth(name, settings, auth_source) do
      :ok ->
        :ok

      {:error, reason} ->
        # Remove the half-initialized container so a retry recreates it and
        # re-attempts the credential copy instead of reusing it.
        case engine_cmd(settings.engine, ["rm", "--force", name]) do
          {:ok, {_cleanup_output, 0}} ->
            {:error, reason}

          {:ok, {cleanup_output, cleanup_status}} ->
            {:error, {:codex_auth_copy_cleanup_failed, reason, name, cleanup_status, cleanup_output}}

          {:error, cleanup_reason} ->
            {:error, {:codex_auth_copy_cleanup_failed, reason, name, cleanup_reason}}
        end
    end
  end

  # Hands the desktop entrypoint everything it needs to capture the virtual
  # display. Recordings are written to the workspace-relative (or absolute)
  # recordings_dir resolved against the in-container workspace mount.
  defp recording_run_args(%{record: true} = settings) do
    [
      "--env",
      "SYMPHONY_DESKTOP_RECORD=1",
      "--env",
      "SYMPHONY_RECORDINGS_DIR=#{container_recordings_dir(settings)}",
      "--env",
      "SYMPHONY_RECORD_FRAMERATE=#{settings.record_framerate}",
      "--env",
      "SYMPHONY_RECORD_SEGMENT_SECONDS=#{settings.record_segment_seconds}"
    ]
  end

  defp recording_run_args(_settings), do: []

  defp container_recordings_dir(%{recordings_dir: "/" <> _absolute = absolute}), do: absolute

  defp container_recordings_dir(%{workspace_mount: workspace_mount, recordings_dir: recordings_dir}), do: Path.join(workspace_mount, recordings_dir)

  @default_codex_auth_file "~/.codex/auth.json"

  # Codex rewrites auth.json whenever it refreshes its OAuth tokens, so
  # bind-mounting the host file into the container breaks: a read-only mount
  # makes the refresh fail, and a read-write single-file mount goes stale
  # because Codex replaces the file via rename (the mount keeps the old
  # inode). Copying at container start gives Codex a private writable copy.
  defp resolve_codex_auth_file(%{codex_auth_file: ""}), do: {:ok, nil}

  defp resolve_codex_auth_file(%{codex_auth_file: configured}) do
    default? = configured == @default_codex_auth_file
    path = expand_codex_auth_file(configured, default?)

    cond do
      File.regular?(path) ->
        {:ok, path}

      default? ->
        Logger.debug("No Codex auth file found at #{path}; skipping credential copy into container")
        {:ok, nil}

      true ->
        {:error, {:codex_auth_file_not_found, path}}
    end
  end

  defp expand_codex_auth_file(configured, default?) do
    codex_home = System.get_env("CODEX_HOME")

    if default? and is_binary(codex_home) and codex_home != "" do
      Path.join(codex_home, "auth.json")
    else
      expand_home(configured)
    end
  end

  defp expand_home("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_home(path), do: Path.expand(path)

  defp install_codex_auth(_name, _settings, nil), do: :ok

  defp install_codex_auth(name, settings, auth_source) do
    container_path = settings.codex_auth_container_path
    container_dir = Path.dirname(container_path)

    with {:ok, {_output, 0}} <- engine_cmd(settings.engine, ["exec", name, "mkdir", "-p", container_dir]),
         {:ok, {_output, 0}} <- engine_cmd(settings.engine, ["cp", auth_source, "#{name}:#{container_path}"]) do
      Logger.info("Copied Codex credentials into container container_name=#{name} source=#{auth_source} destination=#{container_path}")
      :ok
    else
      {:ok, {output, status}} -> {:error, {:codex_auth_copy_failed, name, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_novnc_port(name, settings) do
    case engine_cmd(settings.engine, ["port", name, "#{settings.novnc_container_port}/tcp"]) do
      {:ok, {output, 0}} ->
        parse_published_port(output, name)

      {:ok, {output, status}} ->
        {:error, {:container_port_lookup_failed, name, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_published_port(output, name) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case Regex.run(~r/:(\d+)\s*$/, String.trim(line), capture: :all_but_first) do
        [port] -> String.to_integer(port)
        _ -> nil
      end
    end)
    |> case do
      port when is_integer(port) and port > 0 -> {:ok, port}
      _ -> {:error, {:container_port_lookup_failed, name, :unparsable_output, output}}
    end
  end

  defp novnc_url(advertise_host, port) do
    "http://#{advertise_host}:#{port}/vnc.html?autoconnect=1&resize=scale"
  end

  defp engine_cmd(engine, args) do
    runner = Application.get_env(:symphony_elixir, :container_command_runner, &default_command_runner/2)
    runner.(engine, args)
  end

  defp default_command_runner(engine, args) do
    case System.find_executable(engine) do
      nil ->
        {:error, {:container_engine_not_found, engine}}

      executable ->
        {:ok, System.cmd(executable, args, stderr_to_stdout: true)}
    end
  end
end
