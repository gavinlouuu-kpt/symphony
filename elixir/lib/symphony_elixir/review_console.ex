defmodule SymphonyElixir.ReviewConsole do
  @moduledoc """
  Private in-memory dashboard conversation log for orchestrator/reviewer notes.
  """

  use GenServer

  alias SymphonyElixirWeb.ObservabilityPubSub

  @max_messages 200

  @type message :: %{
          id: pos_integer(),
          issue_identifier: String.t(),
          target: String.t(),
          role: String.t(),
          body: String.t(),
          created_at: DateTime.t()
        }

  defstruct messages: [], next_id: 1

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @spec list(non_neg_integer()) :: [message()]
  def list(limit \\ 50) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:list, limit})
    else
      []
    end
  end

  @spec append(map()) :: {:ok, message()} | {:error, :unavailable}
  def append(attrs) when is_map(attrs) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:append, attrs})
    else
      {:error, :unavailable}
    end
  end

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:list, limit}, _from, state) do
    limit = normalize_limit(limit)
    {:reply, Enum.take(state.messages, limit), state}
  end

  def handle_call({:append, attrs}, _from, state) do
    message = %{
      id: state.next_id,
      issue_identifier: normalize_string(Map.get(attrs, :issue_identifier)),
      target: normalize_string(Map.get(attrs, :target)),
      role: normalize_string(Map.get(attrs, :role)),
      body: normalize_string(Map.get(attrs, :body)),
      created_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    messages = [message | state.messages] |> Enum.take(@max_messages)
    ObservabilityPubSub.broadcast_update()

    {:reply, {:ok, message}, %{state | messages: messages, next_id: state.next_id + 1}}
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_messages)
  defp normalize_limit(_limit), do: 50

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: to_string(value || "")
end
