defmodule Ourocode.Runtime.Stream.MailboxPressure do
  @moduledoc """
  Pure overflow and backpressure policy calculations for stream mailboxes.
  """

  @type overflow :: Ourocode.Runtime.Stream.Mailbox.overflow()
  @type backpressure :: Ourocode.Runtime.Stream.Mailbox.backpressure()

  @spec overflow(map(), map()) :: overflow()
  def overflow(state, event) do
    %{
      overflow_path: state.stream_mailbox_overflow_path,
      overflow_behavior: :drop_newest,
      stream_kind: state.stream_kind,
      event_seq: Map.get(event, :event_seq),
      dropped_event_seq: Map.get(event, :event_seq),
      capacity: state.stream_mailbox_capacity,
      retained_pending_count: state.stream_mailbox_pending_count
    }
  end

  @spec backpressure?(map()) :: boolean()
  def backpressure?(%{stream_mailbox_backpressure_behavior: :none}), do: false

  def backpressure?(state) do
    state.stream_mailbox_pending_count >= state.stream_mailbox_backpressure_threshold
  end

  @spec backpressure(map(), map()) :: backpressure()
  def backpressure(state, event) do
    %{
      backpressure_behavior: state.stream_mailbox_backpressure_behavior,
      stream_kind: state.stream_kind,
      event_seq: Map.get(event, :event_seq),
      threshold: state.stream_mailbox_backpressure_threshold,
      capacity: state.stream_mailbox_capacity,
      pending_count: state.stream_mailbox_pending_count,
      delay_ms: delay_ms(state)
    }
  end

  @spec relief(map(), map(), non_neg_integer()) :: backpressure()
  def relief(state, event, previous_pending_count) do
    %{
      backpressure_behavior: state.stream_mailbox_backpressure_behavior,
      stream_kind: state.stream_kind,
      event_seq: Map.get(event, :event_seq),
      threshold: state.stream_mailbox_backpressure_threshold,
      capacity: state.stream_mailbox_capacity,
      pending_count: state.stream_mailbox_pending_count,
      previous_pending_count: previous_pending_count,
      delay_ms: 0
    }
  end

  @spec release_relief(map(), non_neg_integer()) :: backpressure()
  def release_relief(state, previous_pending_count) do
    %{
      backpressure_behavior: state.stream_mailbox_backpressure_behavior,
      stream_kind: state.stream_kind,
      event_seq: Map.get(state.stream_cursor, :event_seq),
      threshold: state.stream_mailbox_backpressure_threshold,
      capacity: state.stream_mailbox_capacity,
      pending_count: 0,
      previous_pending_count: previous_pending_count,
      delay_ms: 0
    }
  end

  @spec delay_ms(map()) :: non_neg_integer()
  def delay_ms(%{stream_mailbox_backpressure_behavior: :delay} = state) do
    state.stream_mailbox_backpressure_delay_ms
  end

  def delay_ms(_state), do: 0
end
