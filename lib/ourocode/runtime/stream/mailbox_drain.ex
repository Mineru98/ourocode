defmodule Ourocode.Runtime.Stream.MailboxDrain do
  @moduledoc """
  Drain scheduling policy for bounded stream mailboxes.
  """

  @drain_message :drain_stream_mailbox

  @spec schedule(map()) :: map()
  def schedule(%{stream_mailbox_drain_interval_ms: :manual} = state), do: state

  def schedule(%{stream_mailbox_pending_count: 0} = state) do
    Map.put(state, :stream_mailbox_draining?, false)
  end

  def schedule(%{stream_mailbox_draining?: true} = state), do: state

  def schedule(state) do
    Process.send_after(self(), @drain_message, state.stream_mailbox_drain_interval_ms)
    Map.put(state, :stream_mailbox_draining?, true)
  end
end
