defmodule SymphonyElixir.OpenClaw.Client do
  @moduledoc """
  Thin wrapper around the OpenClaw CLI message surface.
  """

  @type settings :: %{
          command: String.t() | nil,
          channel: String.t() | nil,
          account: String.t() | nil,
          target: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @type thread_ref :: %{
          optional(:thread_id) => String.t(),
          optional(:target) => String.t(),
          optional(:raw) => term()
        }

  @spec send_message(String.t(), settings()) :: :ok | {:error, term()}
  def send_message(message, settings) when is_binary(message) do
    with {:ok, executable, base_args} <- command_parts(settings.command),
         {:ok, executable_path} <- executable_path(executable),
         {:ok, args} <- message_args(base_args, message, settings) do
      run_command(executable_path, args, settings.timeout_ms)
    end
  end

  @spec create_thread(String.t(), String.t(), settings()) :: {:ok, thread_ref()} | {:error, term()}
  def create_thread(message, thread_name, settings) when is_binary(message) and is_binary(thread_name) do
    with {:ok, executable, base_args} <- command_parts(settings.command),
         {:ok, executable_path} <- executable_path(executable),
         {:ok, args} <- thread_create_args(base_args, message, thread_name, settings),
         {:ok, output} <- run_command_output(executable_path, args, settings.timeout_ms) do
      parse_thread_create_output(output)
    end
  end

  @spec reply_to_thread(String.t(), thread_ref(), settings()) :: :ok | {:error, term()}
  def reply_to_thread(message, thread_ref, settings) when is_binary(message) do
    with {:ok, executable, base_args} <- command_parts(settings.command),
         {:ok, executable_path} <- executable_path(executable),
         {:ok, args} <- thread_reply_args(base_args, message, thread_ref, settings) do
      run_command(executable_path, args, settings.timeout_ms)
    end
  end

  defp command_parts(command) when is_binary(command) do
    command
    |> OptionParser.split()
    |> case do
      [executable | args] -> {:ok, executable, args}
      [] -> {:error, :missing_openclaw_command}
    end
  rescue
    _error -> {:error, {:invalid_openclaw_command, command}}
  end

  defp command_parts(_command), do: {:error, :missing_openclaw_command}

  defp executable_path(executable) when is_binary(executable) do
    cond do
      String.contains?(executable, "/") ->
        path = Path.expand(executable)
        if File.regular?(path), do: {:ok, path}, else: {:error, {:openclaw_executable_not_found, executable}}

      path = System.find_executable(executable) ->
        {:ok, path}

      true ->
        {:error, {:openclaw_executable_not_found, executable}}
    end
  end

  defp message_args(base_args, message, settings) do
    with {:ok, channel} <- required_setting(settings.channel, :missing_openclaw_channel),
         {:ok, target} <- required_setting(settings.target, :missing_openclaw_target) do
      args =
        base_args ++
          [
            "message",
            "send",
            "--channel",
            channel
          ] ++
          optional_arg("--account", settings.account) ++
          [
            "--target",
            target,
            "--message",
            message
          ]

      {:ok, args}
    end
  end

  defp thread_create_args(base_args, message, thread_name, settings) do
    with {:ok, channel} <- required_setting(settings.channel, :missing_openclaw_channel),
         {:ok, target} <- required_setting(settings.target, :missing_openclaw_target),
         {:ok, thread_name} <- required_setting(thread_name, :missing_openclaw_thread_name) do
      args =
        base_args ++
          [
            "message",
            "thread",
            "create",
            "--channel",
            channel
          ] ++
          optional_arg("--account", settings.account) ++
          [
            "--target",
            target,
            "--thread-name",
            thread_name,
            "--message",
            message,
            "--json"
          ]

      {:ok, args}
    end
  end

  defp thread_reply_args(base_args, message, thread_ref, settings) do
    with {:ok, channel} <- required_setting(settings.channel, :missing_openclaw_channel),
         {:ok, target} <- required_setting(thread_target(thread_ref), :missing_openclaw_thread_target) do
      args =
        base_args ++
          [
            "message",
            "send",
            "--channel",
            channel
          ] ++
          optional_arg("--account", settings.account) ++
          [
            "--target",
            target,
            "--message",
            message
          ]

      {:ok, args}
    end
  end

  defp required_setting(value, error) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, error}, else: {:ok, value}
  end

  defp required_setting(_value, error), do: {:error, error}

  defp optional_arg(_name, nil), do: []
  defp optional_arg(_name, ""), do: []

  defp optional_arg(name, value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      trimmed -> [name, trimmed]
    end
  end

  defp optional_arg(_name, _value), do: []

  defp run_command(executable_path, args, timeout_ms) do
    case run_command_output(executable_path, args, timeout_ms) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_command_output(executable_path, args, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd(executable_path, args, stderr_to_stdout: true)}
        rescue
          error -> {:error, {:openclaw_command_failed, Exception.message(error)}}
        catch
          kind, reason -> {:error, {:openclaw_command_failed, {kind, reason}}}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {output, 0}}} ->
        {:ok, output}

      {:ok, {:ok, {output, status}}} ->
        {:error, {:openclaw_exit_status, status, summarize_output(output)}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      nil ->
        {:error, :openclaw_timeout}
    end
  end

  defp parse_thread_create_output(output) do
    with {:ok, decoded} <- decode_json_output(output),
         {:ok, thread_id} <- extract_thread_id(decoded) do
      {:ok, %{thread_id: thread_id, target: "channel:#{thread_id}", raw: decoded}}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:openclaw_invalid_json, summarize_output(output), Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_json_output(output) when is_binary(output) do
    trimmed = String.trim(output)

    case Jason.decode(trimmed) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, error} ->
        case json_object_fragment(trimmed) do
          nil -> {:error, error}
          fragment -> Jason.decode(fragment)
        end
    end
  end

  defp json_object_fragment(output) do
    with {start, _length} <- :binary.match(output, "{"),
         matches when matches != [] <- :binary.matches(output, "}") do
      {last, 1} = List.last(matches)
      binary_part(output, start, last - start + 1)
    else
      _ -> nil
    end
  end

  defp extract_thread_id(%{"thread" => %{"id" => id}}), do: normalize_id(id)
  defp extract_thread_id(%{"payload" => %{"thread" => %{"id" => id}}}), do: normalize_id(id)
  defp extract_thread_id(%{"result" => %{"thread" => %{"id" => id}}}), do: normalize_id(id)

  defp extract_thread_id(decoded) do
    case find_first_key(decoded, ["threadId", "thread_id", "messageThreadId", "message_thread_id"]) do
      nil -> {:error, :missing_openclaw_thread_id}
      value -> normalize_id(value)
    end
  end

  defp find_first_key(%{} = map, keys) do
    Enum.find_value(keys, &Map.get(map, &1)) ||
      map
      |> Map.values()
      |> Enum.find_value(&find_first_key(&1, keys))
  end

  defp find_first_key(values, keys) when is_list(values), do: Enum.find_value(values, &find_first_key(&1, keys))
  defp find_first_key(_value, _keys), do: nil

  defp normalize_id(id) when is_binary(id) do
    id = String.trim(id)
    if id == "", do: {:error, :missing_openclaw_thread_id}, else: {:ok, id}
  end

  defp normalize_id(id) when is_integer(id), do: {:ok, Integer.to_string(id)}
  defp normalize_id(id), do: {:error, {:invalid_openclaw_thread_id, id}}

  defp thread_target(%{target: target}) when is_binary(target), do: target
  defp thread_target(%{"target" => target}) when is_binary(target), do: target
  defp thread_target(%{thread_id: thread_id}), do: id_target(thread_id)
  defp thread_target(%{"thread_id" => thread_id}), do: id_target(thread_id)
  defp thread_target(%{"threadId" => thread_id}), do: id_target(thread_id)
  defp thread_target(thread_id) when is_binary(thread_id), do: id_target(thread_id)
  defp thread_target(_thread_ref), do: nil

  defp id_target(thread_id) do
    case normalize_id(thread_id) do
      {:ok, id} -> "channel:#{id}"
      {:error, _reason} -> nil
    end
  end

  defp summarize_output(output) when is_binary(output) do
    output
    |> String.trim()
    |> String.slice(0, 2_000)
  end

  defp summarize_output(output), do: inspect(output, limit: 20, printable_limit: 2_000)
end
