defmodule Ourocode.Config.RuntimeDefaultsTest do
  use ExUnit.Case, async: false

  alias Ourocode.Config.RuntimeDefaults

  setup do
    tracked_keys = [
      :parallel_child_count,
      :repeat_count,
      :stream_mailbox_capacity,
      :stream_mailbox_overflow_path,
      :stream_mailbox_backpressure_threshold,
      :stream_mailbox_backpressure_behavior,
      :stream_mailbox_backpressure_delay_ms,
      :allowed_memory_growth_mb,
      :stale_cleanup_timeout_ms,
      :operation_timeout_ms,
      :stream_subscription_cleanup_timeout_ms,
      :pane_state_retention_ms,
      :cleanup_policy
    ]

    previous = Map.new(tracked_keys, &{&1, Application.get_env(:ourocode, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value) do
          Application.delete_env(:ourocode, key)
        else
          Application.put_env(:ourocode, key, value)
        end
      end)
    end)
  end

  test "builds runtime defaults from application environment" do
    Application.put_env(:ourocode, :parallel_child_count, 4)
    Application.put_env(:ourocode, :stream_mailbox_overflow_path, "notify")
    Application.put_env(:ourocode, :stream_mailbox_backpressure_behavior, :delay)

    defaults = RuntimeDefaults.defaults()

    assert defaults.parallel_child_count == 4
    assert defaults.stream_mailbox_overflow_path == :notify
    assert defaults.stream_mailbox_backpressure_behavior == :delay
    assert defaults.cleanup_policy == RuntimeDefaults.cleanup_policy()
  end

  test "applies caller overrides after configured defaults" do
    Application.put_env(:ourocode, :repeat_count, 5)

    defaults = RuntimeDefaults.defaults(%{repeat_count: 2, stale_cleanup_timeout_ms: 10})

    assert defaults.repeat_count == 2
    assert defaults.stale_cleanup_timeout_ms == 10
    assert defaults.cleanup_policy.stale_cleanup_timeout_ms == 10
  end
end
