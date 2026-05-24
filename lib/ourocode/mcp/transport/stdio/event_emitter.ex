defmodule Ourocode.MCP.Transport.Stdio.EventEmitter do
  @moduledoc """
  Emits, persists, and delivers lifecycle events for the stdio transport.

  The stdio transport owns port I/O and JSON-RPC correlation. This module owns
  the repeated event bookkeeping around sequence numbers, journal persistence,
  and sink delivery.
  """

  alias Ourocode.Journal
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.Stdio.RawEvent

  @doc """
  Builds a lifecycle event from transport state and payload, then emits it.
  """
  @spec emit(map(), atom(), map()) :: map()
  def emit(state, type, payload) when is_map(state) and is_atom(type) and is_map(payload) do
    payload = Map.new(payload)
    external_ids = Map.get(payload, :external_ids, Map.fetch!(state, :external_ids))

    event =
      state
      |> context()
      |> Map.put(:transport, :stdio)
      |> Map.put(:external_ids, external_ids)
      |> Map.merge(payload)
      |> then(&LifecycleEvent.new(type, &1))

    emit_normalized(state, event)
  end

  @doc """
  Persists and delivers an already-normalized lifecycle event.
  """
  @spec emit_normalized(map(), LifecycleEvent.t()) :: map()
  def emit_normalized(state, %LifecycleEvent{} = event) when is_map(state) do
    persist(Map.get(state, :journal_path), event)
    deliver(Map.get(state, :event_sink), event)
    %{state | event_seq: event.event_seq}
  end

  @doc """
  Returns the common lifecycle context for the next stdio event.
  """
  @spec context(map()) :: map()
  def context(state) when is_map(state) do
    %{
      event_seq: Map.fetch!(state, :event_seq) + 1,
      parent_call_id: Map.fetch!(state, :parent_call_id),
      runtime_source: Map.fetch!(state, :runtime_source),
      external_ids: Map.fetch!(state, :external_ids),
      occurred_at_ms: System.system_time(:millisecond)
    }
  end

  defp persist(nil, _event), do: :ok

  defp persist(path, event) when is_binary(path) do
    Journal.append!(path, RawEvent.canonical_journal_event(event))
  end

  defp deliver(pid, event) when is_pid(pid), do: send(pid, {:ourocode_event, event})
  defp deliver(fun, event) when is_function(fun, 1), do: fun.(event)
  defp deliver(_sink, _event), do: :ok
end
