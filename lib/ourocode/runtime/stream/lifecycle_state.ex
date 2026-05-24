defmodule Ourocode.Runtime.Stream.LifecycleState do
  @moduledoc """
  Initial lifecycle state for supervised runtime streams.
  """

  alias Ourocode.Config
  alias Ourocode.Runtime.Stream.Timers

  @spec fields(keyword(), integer()) :: map()
  def fields(opts, now_ms) when is_list(opts) and is_integer(now_ms) do
    config = Config.defaults()
    timeout_ms = Keyword.get(opts, :stale_cleanup_timeout_ms, config.stale_cleanup_timeout_ms)

    %{
      stream_status: :active,
      stream_last_activity_monotonic_ms: now_ms,
      stream_stale_cleanup_timeout_ms: timeout_ms,
      stream_subscription_cleanup_timeout_ms:
        Keyword.get(
          opts,
          :stream_subscription_cleanup_timeout_ms,
          config.stream_subscription_cleanup_timeout_ms
        ),
      stream_operation_timeout_ms:
        Keyword.get(opts, :operation_timeout_ms, config.operation_timeout_ms),
      stream_active_operation_timeout_ms: nil,
      stream_active_operation_id: nil,
      stream_operation_started_monotonic_ms: nil,
      stream_operation_deadline_monotonic_ms: nil,
      stream_operation_timer_ref: nil,
      stream_operation_timeout_count: 0,
      stream_lifecycle_target: Keyword.get(opts, :stream_lifecycle_target),
      stream_operation_timeout_target: Keyword.get(opts, :stream_operation_timeout_target),
      stream_cleanup_target: Keyword.get(opts, :stream_cleanup_target),
      stream_cleanup_action: Keyword.get(opts, :stream_cleanup_action, :stop),
      stream_process_handles: Keyword.get(opts, :stream_process_handles, []),
      stream_subscriptions: Keyword.get(opts, :stream_subscriptions, []),
      stream_registered_buffers: Keyword.get(opts, :stream_registered_buffers, []),
      stream_cleanup_started_monotonic_ms: nil,
      stream_cleanup_reason: nil,
      stream_idle_timer_ref: Timers.schedule_idle(timeout_ms, now_ms)
    }
  end
end
