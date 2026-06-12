defmodule SymphonyElixir.ContainerRuntime do
  @moduledoc """
  Manages one desktop-enabled container per issue so agents run isolated from
  the host and operators can watch (and drive) each agent's virtual desktop
  from the web dashboard via noVNC.
  """

  require Logger
  alias SymphonyElixir.Config

  @type container_info :: %{
          container_id: String.t(),
          container_name: String.t(),
          image: String.t(),
          engine: String.t(),
          workspace_mount: String.t(),
          novnc_port: pos_integer(),
          novnc_url: String.t()
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

    with {:ok, container_id} <- start_or_reuse(name, workspace, settings),
         {:ok, novnc_port} <- resolve_novnc_port(name, settings) do
      {:ok,
       %{
         container_id: container_id,
         container_name: name,
         image: settings.image,
         engine: settings.engine,
         workspace_mount: settings.workspace_mount,
         novnc_port: novnc_port,
         novnc_url: novnc_url(settings, novnc_port)
       }}
    end
  end

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

  defp start_or_reuse(name, workspace, settings) do
    case engine_cmd(settings.engine, ["inspect", "--format", "{{.Id}} {{.State.Running}}", name]) do
      {:ok, {output, 0}} ->
        case String.split(String.trim(output)) do
          [container_id, "true"] ->
            {:ok, container_id}

          _ ->
            replace_container(name, workspace, settings)
        end

      {:ok, {_output, _status}} ->
        run_container(name, workspace, settings)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_container(name, workspace, settings) do
    case engine_cmd(settings.engine, ["rm", "--force", name]) do
      {:ok, {_output, 0}} -> run_container(name, workspace, settings)
      {:ok, {output, status}} -> {:error, {:container_remove_failed, name, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_container(name, workspace, settings) do
    args =
      [
        "run",
        "--detach",
        "--name",
        name,
        "--label",
        "symphony.managed=true",
        "--volume",
        "#{workspace}:#{settings.workspace_mount}",
        "--publish",
        "#{settings.novnc_host}::#{settings.novnc_container_port}"
      ] ++ settings.extra_run_args ++ [settings.image]

    case engine_cmd(settings.engine, args) do
      {:ok, {output, 0}} ->
        Logger.info("Started agent container container_name=#{name} image=#{settings.image} workspace=#{workspace}")
        {:ok, String.trim(output)}

      {:ok, {output, status}} ->
        {:error, {:container_start_failed, name, status, output}}

      {:error, reason} ->
        {:error, reason}
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

  defp novnc_url(settings, port) do
    "http://#{settings.novnc_host}:#{port}/vnc.html?autoconnect=1&resize=scale"
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
