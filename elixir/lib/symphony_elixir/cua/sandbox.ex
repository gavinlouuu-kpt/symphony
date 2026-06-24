defmodule SymphonyElixir.Cua.Sandbox do
  @moduledoc false

  require Logger

  alias SymphonyElixir.{Config, SSH}
  alias SymphonyElixir.Linear.Issue

  @container_ports %{
    ssh: 22,
    vnc: 5901,
    novnc: 6901,
    api: 8000
  }

  @spec ensure_for_issue(map() | String.t() | nil) :: {:ok, map()} | {:error, term()}
  def ensure_for_issue(issue_or_identifier) do
    settings = Config.settings!()
    cua = settings.cua
    name = sandbox_name(issue_or_identifier, cua.name_prefix)

    with {:ok, executable} <- executable(cua.executable),
         {:ok, runtime} <- ensure_container(executable, name, issue_context(issue_or_identifier), cua) do
      {:ok, runtime}
    end
  end

  @spec delete_for_issue(map() | String.t() | nil) :: :ok
  def delete_for_issue(issue_or_identifier) do
    settings = Config.settings!()

    if settings.worker.provider == "cua" and settings.cua.delete_on_terminal do
      name = sandbox_name(issue_or_identifier, settings.cua.name_prefix)

      with {:ok, executable} <- executable(settings.cua.executable) do
        case docker(executable, ["rm", "-f", name]) do
          {:ok, _output} ->
            Logger.info("Deleted CUA sandbox name=#{name}")

          {:error, {_args, _status, output}} ->
            if not String.contains?(output, "No such container") do
              Logger.warning("Failed to delete CUA sandbox name=#{name}: #{inspect(output)}")
            end
        end
      end
    end

    :ok
  end

  @spec sandbox_name(map() | String.t() | nil, String.t()) :: String.t()
  def sandbox_name(issue_or_identifier, prefix) when is_binary(prefix) do
    suffix =
      issue_or_identifier
      |> issue_identifier()
      |> safe_name_part()

    prefix =
      prefix
      |> safe_name_part()
      |> case do
        "" -> "symphony"
        value -> value
      end

    [prefix, suffix]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("-")
    |> String.slice(0, 63)
    |> String.trim_trailing("-")
  end

  defp ensure_container(executable, name, issue_context, cua) do
    case container_running?(executable, name) do
      {:ok, true} ->
        Logger.info("Reusing running CUA sandbox name=#{name}")
        runtime_from_container(executable, name, cua)

      {:ok, false} ->
        Logger.info("Starting existing CUA sandbox name=#{name}")

        with {:ok, _output} <- docker(executable, ["start", name]),
             :ok <- maybe_wait_for_ssh(executable, name, cua) do
          runtime_from_container(executable, name, cua)
        end

      {:error, :not_found} ->
        launch_container(executable, name, issue_context, cua)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp launch_container(executable, name, issue_context, cua) do
    with {:ok, ports} <- reserve_ports(cua, name),
         args <- docker_run_args(name, issue_context, ports, cua),
         {:ok, _output} <- docker(executable, args),
         :ok <- maybe_wait_for_ssh_ports(ports, cua) do
      Logger.info("Launched CUA sandbox name=#{name} ssh_port=#{ports.ssh} novnc_port=#{ports.novnc} api_port=#{ports.api}")
      {:ok, runtime(name, ports, cua)}
    else
      {:error, {_args, _status, output}} = error ->
        if String.contains?(output, "Conflict") and String.contains?(output, name) do
          runtime_from_container(executable, name, cua)
        else
          error
        end

      error ->
        error
    end
  end

  defp docker_run_args(name, issue_context, ports, cua) do
    host = cua_host(cua)

    [
      "run",
      "-d",
      "--name",
      name,
      "--label",
      "symphony.cua=true",
      "--label",
      "symphony.issue_id=#{issue_context.issue_id || ""}",
      "--label",
      "symphony.issue_identifier=#{issue_context.issue_identifier || ""}",
      "-p",
      "#{host}:#{ports.ssh}:#{@container_ports.ssh}",
      "-p",
      "#{host}:#{ports.vnc}:#{@container_ports.vnc}",
      "-p",
      "#{host}:#{ports.novnc}:#{@container_ports.novnc}",
      "-p",
      "#{host}:#{ports.api}:#{@container_ports.api}"
    ] ++
      env_args(cua.env) ++
      mounted_secret_args(cua) ++
      configured_volume_args(cua.volumes) ++
      (cua.docker_args || []) ++
      [cua.image]
  end

  defp env_args(env) when is_map(env) do
    env
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.flat_map(fn {key, value} ->
      ["-e", "#{key}=#{value}"]
    end)
  end

  defp env_args(_env), do: []

  defp mounted_secret_args(cua) do
    []
    |> maybe_mount_file(cua.ssh_authorized_key_path, "/run/symphony/ssh/authorized_key.pub")
    |> maybe_mount_file(cua.codex_auth_path, "/run/symphony/codex/auth.json")
    |> maybe_mount_file(cua.codex_config_path, "/run/symphony/codex/config.toml")
  end

  defp maybe_mount_file(args, path, target) when is_binary(path) and is_binary(target) do
    if File.regular?(path) do
      args ++ ["-v", "#{path}:#{target}:ro"]
    else
      args
    end
  end

  defp maybe_mount_file(args, _path, _target), do: args

  defp configured_volume_args(volumes) when is_list(volumes) do
    Enum.flat_map(volumes, fn
      volume when is_binary(volume) and volume != "" -> ["-v", volume]
      _ -> []
    end)
  end

  defp configured_volume_args(_volumes), do: []

  defp runtime_from_container(executable, name, cua) do
    with {:ok, ports} <- published_ports(executable, name),
         :ok <- require_port(ports, :ssh) do
      {:ok, runtime(name, ports, cua)}
    end
  end

  defp published_ports(executable, name) do
    Enum.reduce_while(@container_ports, {:ok, %{}}, fn {key, container_port}, {:ok, acc} ->
      case docker(executable, ["port", name, "#{container_port}/tcp"]) do
        {:ok, output} ->
          {:cont, {:ok, Map.put(acc, key, parse_published_port(output))}}

        {:error, {_args, _status, _output}} ->
          {:cont, {:ok, Map.put(acc, key, nil)}}
      end
    end)
  end

  defp parse_published_port(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> List.first()
    |> case do
      nil ->
        nil

      line ->
        case Regex.run(~r/:(\d+)\s*$/, line, capture: :all_but_first) do
          [port] -> String.to_integer(port)
          _ -> nil
        end
    end
  end

  defp require_port(ports, key) do
    case Map.get(ports, key) do
      port when is_integer(port) -> :ok
      _ -> {:error, {:missing_cua_port, key}}
    end
  end

  defp runtime(name, ports, cua) do
    host = cua_host(cua)
    ssh_target = "#{cua.ssh_user}@#{host}:#{ports.ssh}"

    %{
      worker_host: ssh_target,
      sandbox: %{
        name: name,
        provider: "cua",
        driver: "docker",
        source: "docker",
        status: "running",
        host: host,
        ssh_target: ssh_target,
        ssh_port: ports.ssh,
        lifecycle: sandbox_lifecycle(cua),
        vnc_url: maybe_url("vnc", host, ports.vnc),
        novnc_url: maybe_url("http", host, ports.novnc),
        api_url: maybe_url("http", host, ports.api)
      }
    }
  end

  defp maybe_url(_scheme, _host, nil), do: nil
  defp maybe_url("vnc", host, port), do: "vnc://#{host}:#{port}"
  defp maybe_url("http", host, port), do: "http://#{host}:#{port}/"

  defp sandbox_lifecycle(%{delete_on_terminal: true}), do: "delete_on_terminal"
  defp sandbox_lifecycle(_cua), do: "preserve"

  defp cua_host(%{host: host}) when is_binary(host) do
    case String.trim(host) do
      "" -> "127.0.0.1"
      value -> value
    end
  end

  defp cua_host(_cua), do: "127.0.0.1"

  defp reserve_ports(cua, name) do
    span = cua.port_span
    seed = :erlang.phash2(name, span)

    0..(span - 1)
    |> Enum.find_value(fn step ->
      offset = rem(seed + step, span)

      ports = %{
        ssh: cua.ssh_port_start + offset,
        vnc: cua.vnc_port_start + offset,
        novnc: cua.novnc_port_start + offset,
        api: cua.api_port_start + offset
      }

      if host_ports_available?(ports, cua_host(cua)), do: ports
    end)
    |> case do
      nil -> {:error, {:no_available_cua_ports, span}}
      ports -> {:ok, ports}
    end
  end

  defp host_ports_available?(ports, host) do
    Enum.all?(ports, fn {_key, port} -> valid_port?(port) and host_port_available?(host, port) end)
  end

  defp valid_port?(port), do: is_integer(port) and port > 0 and port <= 65_535

  defp host_port_available?(host, port) do
    case :gen_tcp.listen(port, [:binary, active: false, ip: listen_ip(host), reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp listen_ip(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} when tuple_size(ip) == 4 -> ip
      _ -> {127, 0, 0, 1}
    end
  end

  defp listen_ip(_host), do: {127, 0, 0, 1}

  defp maybe_wait_for_ssh(executable, name, cua) do
    with {:ok, ports} <- published_ports(executable, name) do
      maybe_wait_for_ssh_ports(ports, cua)
    end
  end

  defp maybe_wait_for_ssh_ports(_ports, %{wait_for_ssh: false}), do: :ok

  defp maybe_wait_for_ssh_ports(ports, cua) do
    case Map.get(ports, :ssh) do
      port when is_integer(port) ->
        deadline = deadline_ms(cua.launch_timeout_ms)

        with :ok <- wait_for_tcp(cua_host(cua), port, deadline) do
          wait_for_ssh("#{cua.ssh_user}@#{cua_host(cua)}:#{port}", deadline)
        end

      _ ->
        {:error, {:missing_cua_port, :ssh}}
    end
  end

  defp wait_for_tcp(host, port, deadline_ms) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          {:error, {:cua_ssh_not_ready, port, reason}}
        else
          Process.sleep(250)
          wait_for_tcp(host, port, deadline_ms)
        end
    end
  end

  defp wait_for_ssh(target, deadline_ms) do
    case SSH.run(target, "printf symphony-cua-ready", stderr_to_stdout: true) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        retry_ssh_probe(target, deadline_ms, {:status, status, String.slice(output, 0, 1_000)})

      {:error, reason} ->
        retry_ssh_probe(target, deadline_ms, reason)
    end
  end

  defp retry_ssh_probe(target, deadline_ms, reason) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      {:error, {:cua_ssh_not_ready, target, reason}}
    else
      Process.sleep(500)
      wait_for_ssh(target, deadline_ms)
    end
  end

  defp deadline_ms(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp container_running?(executable, name) do
    case docker(executable, ["inspect", "--format", "{{.State.Running}}", name]) do
      {:ok, output} ->
        {:ok, String.trim(output) == "true"}

      {:error, {_args, _status, output}} ->
        if String.contains?(output, "No such object") or String.contains?(output, "No such container") do
          {:error, :not_found}
        else
          {:error, {:docker_inspect_failed, output}}
        end
    end
  end

  defp docker(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {args, status, output}}
    end
  rescue
    error -> {:error, error}
  end

  defp executable(path) when is_binary(path) do
    cond do
      Path.type(path) == :absolute and File.exists?(path) ->
        {:ok, path}

      Path.type(path) == :absolute ->
        {:error, {:cua_executable_not_found, path}}

      executable = System.find_executable(path) ->
        {:ok, executable}

      true ->
        {:error, {:cua_executable_not_found, path}}
    end
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    %{issue_id: issue_id, issue_identifier: identifier}
  end

  defp issue_context(%{} = issue) do
    %{
      issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
      issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier")
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{issue_id: nil, issue_identifier: identifier}
  end

  defp issue_context(_issue), do: %{issue_id: nil, issue_identifier: nil}

  defp issue_identifier(%Issue{identifier: identifier, id: id}), do: identifier || id
  defp issue_identifier(%{} = issue), do: Map.get(issue, :identifier) || Map.get(issue, "identifier") || Map.get(issue, :id) || Map.get(issue, "id")
  defp issue_identifier(identifier) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: "issue"

  defp safe_name_part(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.-]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
