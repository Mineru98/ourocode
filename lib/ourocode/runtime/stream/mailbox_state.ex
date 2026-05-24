defmodule Ourocode.Runtime.Stream.MailboxState do
  @moduledoc """
  Initial bounded-mailbox state for runtime stream processes.
  """

  alias Ourocode.Config

  @spec fields(keyword()) :: map()
  def fields(opts) when is_list(opts) do
    config = Config.defaults()

    %{
      stream_mailbox_capacity:
        Keyword.get(opts, :stream_mailbox_capacity, config.stream_mailbox_capacity),
      stream_mailbox_overflow_path:
        Keyword.get(opts, :stream_mailbox_overflow_path, config.stream_mailbox_overflow_path),
      stream_mailbox_overflow_target: Keyword.get(opts, :stream_mailbox_overflow_target),
      stream_mailbox_backpressure_threshold:
        Keyword.get(
          opts,
          :stream_mailbox_backpressure_threshold,
          config.stream_mailbox_backpressure_threshold
        ),
      stream_mailbox_backpressure_behavior:
        Keyword.get(
          opts,
          :stream_mailbox_backpressure_behavior,
          config.stream_mailbox_backpressure_behavior
        ),
      stream_mailbox_backpressure_target: Keyword.get(opts, :stream_mailbox_backpressure_target),
      stream_mailbox_backpressure_delay_ms:
        Keyword.get(
          opts,
          :stream_mailbox_backpressure_delay_ms,
          config.stream_mailbox_backpressure_delay_ms
        ),
      stream_mailbox_backpressure_count: 0,
      stream_mailbox_backpressure_active?: false,
      stream_mailbox_final_flush_target: Keyword.get(opts, :stream_mailbox_final_flush_target),
      stream_mailbox_rendered_event_target:
        Keyword.get(opts, :stream_mailbox_rendered_event_target),
      stream_event_subscribers: Keyword.get(opts, :stream_event_subscribers, []),
      stream_mailbox_final_flush_count: 0,
      stream_completion_status: :streaming,
      stream_completion_cursor: nil,
      stream_mailbox_pending: :queue.new(),
      stream_mailbox_pending_count: 0,
      stream_mailbox_overflow_count: 0,
      stream_mailbox_draining?: false,
      stream_mailbox_drain_interval_ms: Keyword.get(opts, :stream_mailbox_drain_interval_ms, 0)
    }
  end
end
