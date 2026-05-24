defmodule Ourocode.Runtime.Stream.MailboxRouting do
  @moduledoc false

  @spec route_backpressure(map(), map()) :: :ok
  def route_backpressure(
        %{
          stream_mailbox_backpressure_behavior: behavior,
          stream_mailbox_backpressure_target: pid
        },
        pressure
      )
      when behavior in [:notify, :delay] and is_pid(pid) do
    send(pid, {:stream_mailbox_backpressure, pressure})
    :ok
  end

  def route_backpressure(_state, _pressure), do: :ok

  @spec route_overflow(map(), map()) :: :ok
  def route_overflow(
        %{stream_mailbox_overflow_path: :notify, stream_mailbox_overflow_target: pid},
        overflow
      )
      when is_pid(pid) do
    send(pid, {:stream_mailbox_overflow, overflow})
    :ok
  end

  def route_overflow(_state, _overflow), do: :ok

  @spec route_final_flush(map(), map()) :: :ok
  def route_final_flush(%{stream_mailbox_final_flush_target: pid}, flush) when is_pid(pid) do
    send(pid, {:stream_mailbox_final_flush, flush})
    :ok
  end

  def route_final_flush(_state, _flush), do: :ok

  @spec route_rendered_event(map(), map()) :: :ok
  def route_rendered_event(%{stream_mailbox_rendered_event_target: pid}, event)
      when is_pid(pid) do
    send(pid, {:stream_mailbox_rendered_event, event})
    :ok
  end

  def route_rendered_event(_state, _event), do: :ok

  @spec route_buffered_event(map(), map()) :: map()
  def route_buffered_event(state, event) do
    Enum.each(Map.get(state, :stream_event_subscribers, []), fn
      pid when is_pid(pid) ->
        send(pid, {:stream_event, event})

      {pid, tag} when is_pid(pid) ->
        send(pid, {tag, event})

      {pid, tag, metadata} when is_pid(pid) and is_map(metadata) ->
        send(pid, {tag, Map.merge(metadata, event)})

      _unsupported ->
        :ok
    end)

    state
  end
end
