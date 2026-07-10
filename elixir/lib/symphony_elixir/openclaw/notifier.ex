defmodule SymphonyElixir.OpenClaw.Notifier do
  @moduledoc """
  Publishes Symphony orchestrator lifecycle events through OpenClaw channels.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.OpenClaw.Client

  @max_message_length 1_900
  @max_thread_name_length 100
  @thread_registry :symphony_openclaw_issue_threads

  @spec publish(atom(), map()) :: :ok
  def publish(event, payload) when is_atom(event) and is_map(payload) do
    with {:ok, settings} <- openclaw_settings(),
         true <- settings.enabled == true,
         true <- event_enabled?(settings, event),
         {:ok, message} <- format_message(event, payload) do
      dispatch(fn -> deliver(event, payload, message, settings) end)
    else
      _ -> :ok
    end
  end

  def publish(_event, _payload), do: :ok

  @doc """
  Returns the stored Discord thread reference for an issue, or nil when no
  thread has been created yet. Accepts any payload shape `issue_thread_keys/1`
  understands (issue struct, issue_id, identifier, issue_url).
  """
  @spec issue_thread_ref(map()) :: map() | nil
  def issue_thread_ref(payload) when is_map(payload) do
    lookup_issue_thread(payload)
  end

  @doc false
  def reset_issue_threads_for_test do
    case :ets.whereis(@thread_registry) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end

    :ok
  end

  defp openclaw_settings do
    {:ok, Config.settings!().openclaw}
  rescue
    error -> {:error, error}
  end

  defp event_enabled?(settings, event) do
    events =
      settings.events
      |> List.wrap()
      |> Enum.map(&normalize_event/1)
      |> MapSet.new()

    MapSet.member?(events, "all") or MapSet.member?(events, normalize_event(event))
  end

  defp normalize_event(event) when is_atom(event), do: event |> Atom.to_string() |> normalize_event()

  defp normalize_event(event) when is_binary(event) do
    event
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_event(event), do: event |> to_string() |> normalize_event()

  defp dispatch(fun) when is_function(fun, 0) do
    if Application.get_env(:symphony_elixir, :openclaw_notify_async, true) do
      dispatch_async(fun)
    else
      fun.()
    end

    :ok
  end

  defp dispatch_async(fun) do
    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      nil -> fun.()
      _pid -> start_async(fun)
    end
  end

  defp start_async(fun) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fun) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("OpenClaw notifier could not start async task: #{inspect(reason)}")
        fun.()
    end
  end

  defp deliver(:dispatch_started, payload, message, settings) do
    client = client_module()

    case lookup_issue_thread(payload) do
      nil ->
        create_dispatch_thread(client, payload, message, settings)

      thread_ref ->
        deliver_existing_dispatch(message, thread_ref, payload, settings)
    end
  end

  defp deliver(_event, payload, message, settings) do
    case lookup_issue_thread(payload) do
      nil -> deliver_channel(message, settings)
      thread_ref -> deliver_thread_reply(message, thread_ref, settings)
    end
  end

  defp create_dispatch_thread(client, payload, message, settings) do
    if client_exports?(client, :create_thread, 3) do
      thread_name = issue_thread_name(payload)

      case client.create_thread(message, thread_name, settings) do
        {:ok, thread_ref} ->
          store_issue_thread(payload, normalize_thread_ref(thread_ref))
          :ok

        {:error, reason} ->
          Logger.warning("OpenClaw thread creation failed: #{inspect(reason)}")
          deliver_channel(message, settings)

        other ->
          Logger.warning("OpenClaw thread creation returned unexpected result: #{inspect(other)}")
          deliver_channel(message, settings)
      end
    else
      deliver_channel(message, settings)
    end
  end

  defp deliver_existing_dispatch(message, thread_ref, payload, settings) do
    if initial_attempt?(Map.get(payload, :attempt) || Map.get(payload, "attempt")) do
      Logger.debug("Skipping duplicate OpenClaw dispatch_started notification for existing issue thread #{inspect(thread_ref)}")
      :ok
    else
      deliver_thread_reply(message, thread_ref, settings)
    end
  end

  defp deliver_thread_reply(message, thread_ref, settings) do
    client = client_module()

    if client_exports?(client, :reply_to_thread, 3) do
      case client.reply_to_thread(message, thread_ref, settings) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("OpenClaw thread reply failed: #{inspect(reason)}")
          deliver_channel(message, settings)

        other ->
          Logger.warning("OpenClaw thread reply returned unexpected result: #{inspect(other)}")
          deliver_channel(message, settings)
      end
    else
      deliver_channel(message, settings)
    end
  end

  # In escripts modules load lazily; function_exported?/3 does not trigger a
  # load, so the first notification after boot would silently skip thread
  # support and post to the parent channel.
  defp client_exports?(client, function, arity) do
    Code.ensure_loaded?(client) and function_exported?(client, function, arity)
  end

  defp deliver_channel(message, settings) do
    case client_module().send_message(message, settings) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("OpenClaw notification failed: #{inspect(reason)}")
        :ok
    end
  end

  defp store_issue_thread(payload, thread_ref) do
    table = ensure_thread_registry()

    payload
    |> issue_thread_keys()
    |> Enum.each(&:ets.insert(table, {&1, thread_ref}))

    persist_thread_registry(table)
  end

  defp lookup_issue_thread(payload) do
    table = ensure_thread_registry()

    payload
    |> issue_thread_keys()
    |> Enum.find_value(fn key ->
      case :ets.lookup(table, key) do
        [{^key, thread_ref}] -> thread_ref
        _ -> nil
      end
    end)
  end

  defp issue_thread_keys(payload) do
    issue = Map.get(payload, :issue) || Map.get(payload, "issue")

    [
      Map.get(payload, :issue_id) || Map.get(payload, "issue_id"),
      Map.get(payload, :identifier) || Map.get(payload, "identifier"),
      Map.get(payload, :issue_url) || Map.get(payload, "issue_url"),
      issue_value(issue, :id),
      issue_value(issue, :identifier),
      issue_value(issue, :url)
    ]
    |> Enum.map(&normalize_key/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp ensure_thread_registry do
    case :ets.whereis(@thread_registry) do
      :undefined ->
        table =
          try do
            :ets.new(@thread_registry, [
              :named_table,
              :public,
              :set,
              read_concurrency: true,
              write_concurrency: true
            ])
          rescue
            ArgumentError -> @thread_registry
          end

        load_thread_registry(table)
        table

      table ->
        table
    end
  end

  defp persist_thread_registry(table) do
    with path when is_binary(path) <- thread_registry_file(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- encode_thread_registry(table) do
      case File.write(path, encoded) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("OpenClaw thread registry write failed: #{inspect(reason)}")
      end
    else
      nil ->
        :ok

      {:error, reason} ->
        Logger.warning("OpenClaw thread registry encode failed: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("OpenClaw thread registry persistence failed: #{Exception.message(error)}")
  end

  defp load_thread_registry(table) do
    with path when is_binary(path) <- thread_registry_file(),
         {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         true <- is_map(decoded) do
      Enum.each(decoded, fn {key, thread_ref} ->
        if is_binary(key) and is_map(thread_ref) do
          :ets.insert(table, {key, normalize_thread_ref(thread_ref)})
        end
      end)
    else
      nil -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("OpenClaw thread registry read failed: #{inspect(reason)}")
      false -> Logger.warning("OpenClaw thread registry was ignored because it is not a JSON object")
    end
  rescue
    error -> Logger.warning("OpenClaw thread registry load failed: #{Exception.message(error)}")
  end

  defp encode_thread_registry(table) do
    table
    |> :ets.tab2list()
    |> Enum.into(%{}, fn {key, thread_ref} ->
      {key, Map.take(thread_ref, [:thread_id, :target])}
    end)
    |> Jason.encode(pretty: true)
  end

  defp thread_registry_file do
    case Application.get_env(:symphony_elixir, :openclaw_thread_registry_file) do
      path when is_binary(path) ->
        path

      _ ->
        case Application.get_env(:symphony_elixir, :log_file) do
          path when is_binary(path) -> path |> Path.dirname() |> Path.join("openclaw-issue-threads.json")
          _ -> nil
        end
    end
  end

  defp normalize_thread_ref(thread_ref) when is_map(thread_ref) do
    thread_id =
      thread_ref
      |> first_value([:thread_id, "thread_id", "threadId", :message_thread_id, "message_thread_id", "messageThreadId"])
      |> normalize_key()

    target =
      thread_ref
      |> first_value([:target, "target"])
      |> normalize_key()

    %{thread_id: thread_id, target: target || id_target(thread_id)}
  end

  defp normalize_thread_ref(thread_id), do: %{thread_id: normalize_key(thread_id), target: id_target(thread_id)}

  defp first_value(map, keys), do: Enum.find_value(keys, &Map.get(map, &1))

  defp id_target(nil), do: nil

  defp id_target(thread_id) do
    case normalize_key(thread_id) do
      nil -> nil
      id -> "channel:#{id}"
    end
  end

  defp normalize_key(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_key(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_key(_value), do: nil

  defp client_module do
    Application.get_env(:symphony_elixir, :openclaw_client_module, Client)
  end

  defp issue_thread_name(payload) do
    issue = Map.get(payload, :issue) || Map.get(payload, "issue")

    [
      issue_value(issue, :identifier) || issue_value(issue, :id) || Map.get(payload, :identifier) ||
        Map.get(payload, :issue_id),
      issue_value(issue, :title)
    ]
    |> compact_lines()
    |> default_thread_name()
    |> sanitize_thread_name()
  end

  defp default_thread_name(""), do: "Symphony issue"
  defp default_thread_name(name), do: name

  defp sanitize_thread_name(name) do
    name =
      name
      |> String.replace(~r/[\r\n\t]+/, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      name == "" ->
        "Symphony issue"

      String.length(name) > @max_thread_name_length ->
        String.slice(name, 0, @max_thread_name_length - 3) <> "..."

      true ->
        name
    end
  end

  defp format_message(:dispatch_started, payload) do
    issue = Map.get(payload, :issue)

    message =
      [
        "Symphony issue dispatched",
        issue_line(issue),
        title_line(issue),
        state_line(issue),
        url_line(issue),
        field_line("Worker", Map.get(payload, :worker_host) || "local"),
        field_line("Attempt", attempt_label(Map.get(payload, :attempt))),
        "Use this thread for status and implementation discussion.",
        "Keep the project channel clear for new issue intake."
      ]
      |> compact_lines()

    {:ok, truncate_message(message)}
  end

  defp format_message(:agent_completed, payload) do
    issue = Map.get(payload, :issue)

    message =
      [
        "Symphony agent completed",
        issue_line(issue),
        title_line(issue),
        url_line(issue),
        field_line("Session", Map.get(payload, :session_id)),
        "Continuation check scheduled."
      ]
      |> compact_lines()

    {:ok, truncate_message(message)}
  end

  defp format_message(:role_agent_completed, payload) do
    issue = Map.get(payload, :issue)

    message =
      [
        "Symphony role agent completed",
        issue_line(issue),
        title_line(issue),
        url_line(issue),
        field_line("Role", Map.get(payload, :role)),
        field_line("Cycle", cycle_label(Map.get(payload, :cycle), Map.get(payload, :max_cycles))),
        field_line("Session", Map.get(payload, :session_id)),
        field_line("Workspace", Map.get(payload, :workspace_path)),
        evidence_summary_line(payload)
      ]
      |> compact_lines()

    {:ok, truncate_message(message)}
  end

  defp format_message(:issue_blocked, payload) do
    issue = Map.get(payload, :issue)

    message =
      [
        "Symphony issue blocked",
        issue_line(issue) || field_line("Issue", Map.get(payload, :identifier) || Map.get(payload, :issue_id)),
        title_line(issue),
        url_line(issue),
        field_line("Reason", Map.get(payload, :error)),
        field_line("Session", Map.get(payload, :session_id)),
        field_line("noVNC", sandbox_value(Map.get(payload, :sandbox), :novnc_url)),
        field_line("API", sandbox_value(Map.get(payload, :sandbox), :api_url))
      ]
      |> compact_lines()

    {:ok, truncate_message(message)}
  end

  defp format_message(:routing_label_restored, payload) do
    issue = Map.get(payload, :issue)

    message =
      [
        "Symphony restored routing label",
        issue_line(issue) || field_line("Issue", Map.get(payload, :identifier) || Map.get(payload, :issue_id)),
        title_line(issue),
        url_line(issue),
        field_line("Labels", Enum.join(List.wrap(Map.get(payload, :labels)), ", ")),
        field_line("Missing evidence", Map.get(payload, :missing_evidence)),
        field_line("Worker", Map.get(payload, :worker_host) || "local"),
        "The routing label was removed before the handoff evidence contract was satisfied.",
        "The agent run continues; complete the evidence contract before removing the label."
      ]
      |> compact_lines()

    {:ok, truncate_message(message)}
  end

  defp format_message(:issue_unrouted, payload) do
    issue = Map.get(payload, :issue)

    status =
      case Map.get(payload, :phase) do
        :draining -> "Agent stops in #{delay_label(Map.get(payload, :grace_ms))} unless routing is restored."
        :stopped -> "Agent stopped and its workspace/sandbox were cleaned up."
        _ -> nil
      end

    message =
      [
        "Symphony issue unrouted",
        issue_line(issue) || field_line("Issue", Map.get(payload, :identifier) || Map.get(payload, :issue_id)),
        title_line(issue),
        url_line(issue),
        field_line("Worker", Map.get(payload, :worker_host) || "local"),
        "The issue lost its required routing label(s) while an agent was running.",
        status
      ]
      |> compact_lines()

    {:ok, truncate_message(message)}
  end

  defp format_message(:retry_scheduled, payload) do
    message =
      [
        "Symphony retry scheduled",
        field_line("Issue", Map.get(payload, :identifier) || Map.get(payload, :issue_id)),
        field_line("URL", Map.get(payload, :issue_url)),
        field_line("Attempt", Map.get(payload, :attempt)),
        field_line("Delay", delay_label(Map.get(payload, :delay_ms))),
        field_line("Reason", Map.get(payload, :error)),
        field_line("Worker", Map.get(payload, :worker_host) || "local")
      ]
      |> compact_lines()

    {:ok, truncate_message(message)}
  end

  defp format_message(_event, _payload), do: :skip

  defp initial_attempt?(nil), do: true
  defp initial_attempt?(0), do: true
  defp initial_attempt?(""), do: true
  defp initial_attempt?("0"), do: true
  defp initial_attempt?("initial"), do: true
  defp initial_attempt?(_attempt), do: false

  defp issue_line(%Issue{} = issue), do: field_line("Issue", issue.identifier || issue.id)
  defp issue_line(_issue), do: nil

  defp title_line(%Issue{title: title}), do: field_line("Title", title)
  defp title_line(_issue), do: nil

  defp state_line(%Issue{state: state}), do: field_line("State", state)
  defp state_line(_issue), do: nil

  defp url_line(%Issue{url: url}), do: field_line("URL", url)
  defp url_line(_issue), do: nil

  defp issue_value(%Issue{} = issue, key), do: Map.get(issue, key)
  defp issue_value(%{} = issue, key), do: Map.get(issue, key) || Map.get(issue, Atom.to_string(key))
  defp issue_value(_issue, _key), do: nil

  defp field_line(_label, nil), do: nil
  defp field_line(_label, ""), do: nil
  defp field_line(label, value), do: "#{label}: #{value}"

  defp sandbox_value(sandbox, key) when is_map(sandbox) do
    Map.get(sandbox, key) || Map.get(sandbox, Atom.to_string(key))
  end

  defp sandbox_value(_sandbox, _key), do: nil

  defp evidence_summary_line(payload) do
    Map.get(payload, :evidence_summary) || Map.get(payload, "evidence_summary")
  end

  defp compact_lines(lines) do
    lines
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("\n", &to_string/1)
  end

  defp attempt_label(nil), do: "initial"
  defp attempt_label(0), do: "initial"
  defp attempt_label(attempt), do: attempt

  defp cycle_label(nil, _max_cycles), do: nil
  defp cycle_label(cycle, nil), do: cycle
  defp cycle_label(cycle, max_cycles), do: "#{cycle}/#{max_cycles}"

  defp delay_label(delay_ms) when is_integer(delay_ms), do: "#{delay_ms}ms"
  defp delay_label(_delay_ms), do: nil

  defp truncate_message(message) when byte_size(message) <= @max_message_length, do: message

  defp truncate_message(message) do
    String.slice(message, 0, @max_message_length - 14) <> "... [truncated]"
  end
end
