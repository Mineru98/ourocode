defmodule Ourocode.MCP.Transport.StreamableHTTP.EventEmitter do
  @moduledoc """
  Persists and delivers lifecycle events for the streamable HTTP transport.
  """

  alias Ourocode.Journal
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.StreamableHTTP.RawEvent

  @spec emit(keyword(), LifecycleEvent.t()) :: :ok
  def emit(options, %LifecycleEvent{} = event) when is_list(options) do
    persist(Keyword.get(options, :journal_path), event)
    deliver(Keyword.get(options, :subscriber), event)
    :ok
  end

  @spec canonical_journal_event(LifecycleEvent.t() | map()) :: map()
  def canonical_journal_event(event), do: RawEvent.canonical_journal_event(event)

  defp persist(nil, _event), do: :ok

  defp persist(path, event) when is_binary(path) do
    Journal.append!(path, canonical_journal_event(event))
  end

  defp deliver(pid, event) when is_pid(pid), do: send(pid, {:ourocode_event, event})
  defp deliver(_subscriber, _event), do: :ok
end
