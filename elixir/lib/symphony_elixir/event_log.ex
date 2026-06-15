defmodule SymphonyElixir.EventLog do
  @moduledoc """
  Durable, append-only per-issue event log used to power the dashboard's
  transcript view.

  Each Codex lifecycle event observed by the orchestrator is appended here so
  operators can review what an agent did during (and after) a run. The log is:

    * **In-memory** in an ETS table for fast transcript rendering, bounded to the
      most recent `memory_limit` events per issue.
    * **Durable** as newline-delimited JSON (`<issue>.jsonl`) under
      `event_log_dir`, so completed runs survive an orchestrator restart.

  High-frequency streaming deltas and token-count chatter are dropped so the
  transcript stays a readable record of meaningful actions (commands, file
  changes, plans, turns, approvals, agent messages).
  """

  use GenServer
  require Logger

  @table :symphony_event_log
  @default_memory_limit 1_000

  @type event :: %{
          seq: pos_integer(),
          at: String.t(),
          event: String.t() | nil,
          message: String.t() | nil,
          session_id: String.t() | nil,
          codex_timestamp: term()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records an event for `issue_identifier`. Best-effort and asynchronous: callers
  on the hot path never block on (or crash from) logging. Noisy streaming/token
  events are filtered out.
  """
  @spec record(String.t(), map(), GenServer.name()) :: :ok
  def record(issue_identifier, attrs, server \\ __MODULE__)

  def record(issue_identifier, %{} = attrs, server) when is_binary(issue_identifier) do
    if significant?(attrs[:event]) do
      GenServer.cast(server, {:record, issue_identifier, attrs})
    else
      :ok
    end
  end

  def record(_issue_identifier, _attrs, _server), do: :ok

  @doc """
  Lists events for `issue_identifier` in chronological order (oldest first).

  Options:
    * `:limit` - return only the most recent N events (still chronological).
  """
  @spec list(String.t(), keyword(), GenServer.name()) :: [event()]
  def list(issue_identifier, opts \\ [], server \\ __MODULE__)

  def list(issue_identifier, opts, server) when is_binary(issue_identifier) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(server, {:list, issue_identifier, opts})
      _ -> []
    end
  end

  def list(_issue_identifier, _opts, _server), do: []

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # Private table owned by this process; all access happens inside callbacks,
    # so multiple instances never collide on a global name.
    table = :ets.new(@table, [:ordered_set, :private])

    dir = Keyword.get(opts, :dir, default_dir())
    File.mkdir_p(dir)

    {:ok,
     %{
       table: table,
       dir: dir,
       memory_limit: Keyword.get(opts, :memory_limit, @default_memory_limit),
       # issue_identifier => {first_seq, last_seq}
       spans: %{},
       hydrated: MapSet.new()
     }}
  end

  @impl true
  def handle_cast({:record, issue_identifier, attrs}, state) do
    {first_seq, last_seq} = Map.get(state.spans, issue_identifier, {1, 0})
    seq = last_seq + 1

    event = %{
      seq: seq,
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      event: stringify(attrs[:event]),
      message: attrs[:message],
      session_id: attrs[:session_id],
      codex_timestamp: attrs[:codex_timestamp]
    }

    :ets.insert(state.table, {{issue_identifier, seq}, event})
    append_to_file(state.dir, issue_identifier, event)

    {first_seq, _count} = prune(state.table, issue_identifier, first_seq, seq, state.memory_limit)

    {:noreply, %{state | spans: Map.put(state.spans, issue_identifier, {first_seq, seq})}}
  end

  @impl true
  def handle_call({:list, issue_identifier, opts}, _from, state) do
    state = maybe_hydrate(state, issue_identifier)
    events = read_events(state.table, issue_identifier)

    events =
      case Keyword.get(opts, :limit) do
        limit when is_integer(limit) and limit > 0 -> Enum.take(events, -limit)
        _ -> events
      end

    {:reply, events, state}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  @doc false
  @spec significant?(term()) :: boolean()
  def significant?(event) do
    normalized = event |> stringify() |> to_string() |> String.downcase()

    not (String.contains?(normalized, "delta") or String.contains?(normalized, "token"))
  end

  defp prune(table, issue_identifier, first_seq, last_seq, limit) do
    count = last_seq - first_seq + 1

    if count > limit do
      :ets.delete(table, {issue_identifier, first_seq})
      prune(table, issue_identifier, first_seq + 1, last_seq, limit)
    else
      {first_seq, count}
    end
  end

  defp read_events(table, issue_identifier) do
    table
    |> :ets.select([{{{issue_identifier, :"$1"}, :"$2"}, [], [:"$2"]}])
    |> Enum.sort_by(& &1.seq)
  end

  defp maybe_hydrate(state, issue_identifier) do
    cond do
      MapSet.member?(state.hydrated, issue_identifier) ->
        state

      Map.has_key?(state.spans, issue_identifier) ->
        %{state | hydrated: MapSet.put(state.hydrated, issue_identifier)}

      true ->
        hydrate_from_file(state, issue_identifier)
    end
  end

  defp hydrate_from_file(state, issue_identifier) do
    hydrated = MapSet.put(state.hydrated, issue_identifier)

    case read_file_events(state.dir, issue_identifier, state.memory_limit) do
      [] ->
        %{state | hydrated: hydrated}

      events ->
        seqs = Enum.map(events, & &1.seq)

        Enum.each(events, fn event ->
          :ets.insert(state.table, {{issue_identifier, event.seq}, event})
        end)

        span = {Enum.min(seqs), Enum.max(seqs)}
        %{state | hydrated: hydrated, spans: Map.put(state.spans, issue_identifier, span)}
    end
  end

  defp read_file_events(dir, issue_identifier, limit) do
    path = file_path(dir, issue_identifier)

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.take(-limit)
        |> Enum.flat_map(&decode_line/1)

      {:error, _reason} ->
        []
    end
  end

  defp decode_line(line) do
    case Jason.decode(line, keys: :atoms) do
      {:ok, %{} = event} -> [normalize_event(event)]
      _ -> []
    end
  end

  defp normalize_event(event) do
    %{
      seq: event[:seq],
      at: event[:at],
      event: event[:event],
      message: event[:message],
      session_id: event[:session_id],
      codex_timestamp: event[:codex_timestamp]
    }
  end

  defp append_to_file(dir, issue_identifier, event) do
    path = file_path(dir, issue_identifier)

    with {:ok, line} <- Jason.encode(event) do
      File.write(path, [line, "\n"], [:append])
    end
  rescue
    error ->
      Logger.warning("EventLog failed to persist event: #{Exception.message(error)}")
      :ok
  end

  defp file_path(dir, issue_identifier) do
    Path.join(dir, "#{sanitize(issue_identifier)}.jsonl")
  end

  defp sanitize(issue_identifier) do
    String.replace(issue_identifier, ~r/[^A-Za-z0-9._-]/, "_")
  end

  defp default_dir do
    Application.get_env(:symphony_elixir, :event_log_dir, Path.join(File.cwd!(), "log/events"))
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)
end
