defmodule Ourocode.Journal.Writer do
  @moduledoc false

  use GenServer

  alias Ourocode.Journal.Codec
  alias Ourocode.Journal.Reader
  alias Ourocode.Journal.Sequence

  @type entry :: map()

  @spec append(Path.t(), map()) :: :ok | {:error, term()}
  def append(path, event) when is_binary(path) do
    with {:ok, pid} <- ensure_started() do
      GenServer.call(pid, {:append, path, event}, :infinity)
    end
  end

  @spec append_returning_event(Path.t(), map()) :: {:ok, entry()} | {:error, term()}
  def append_returning_event(path, event) when is_binary(path) do
    with {:ok, pid} <- ensure_started() do
      GenServer.call(pid, {:append_returning_event, path, event}, :infinity)
    end
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:append, path, event}, _from, state) do
    result = append_unlocked(path, event)
    {:reply, result, state}
  end

  def handle_call({:append_returning_event, path, event}, _from, state) do
    result = append_unlocked_returning_event(path, event)
    {:reply, result, state}
  end

  defp ensure_started do
    case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:already_registered, pid}} when is_pid(pid) -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_unlocked(path, event) do
    case append_unlocked_returning_event(path, event) do
      {:ok, _record} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_unlocked_returning_event(path, event) do
    with :ok <- ensure_parent_dir(path),
         {:ok, record} <- record_for_append(path, event),
         :ok <- File.write(path, [Ourocode.Json.encode!(record), "\n"], [:append, :binary]) do
      {:ok, Codec.decode(record)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_parent_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp record_for_append(path, event) do
    record = Codec.encode(event)

    with {:ok, entries} <- Reader.read_existing_entries(path),
         {:ok, event_seq} <- Sequence.event_seq_for_append(record, entries) do
      {:ok, Map.put(record, "event_seq", event_seq)}
    end
  end
end
