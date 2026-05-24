defmodule Ourocode.Config.OverridesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Config.Overrides

  test "parse normalizes CLI switches and cleanup policy aliases" do
    assert Overrides.parse([
             "--parallel-child-count=5",
             "--stream-mailbox-overflow-path=notify",
             "--stream-mailbox-backpressure-behavior=delay",
             "--cleanup-policy.pane-state-retention-ms=600000"
           ]) ==
             {:ok,
              %{
                parallel_child_count: 5,
                stream_mailbox_overflow_path: :notify,
                stream_mailbox_backpressure_behavior: :delay,
                pane_state_retention_ms: 600_000
              }}
  end

  test "parse separates unsupported and invalid override inputs" do
    assert {:error, unsupported} = Overrides.parse(["--not-real=1"])
    assert unsupported =~ "unsupported config override arguments"

    assert {:error, invalid} = Overrides.parse(["--repeat-count=0"])
    assert invalid =~ "repeat_count must be configured as a positive integer"

    assert {:error, invalid_choice} =
             Overrides.parse(["--stream-mailbox-overflow-path=raise"])

    assert invalid_choice =~ "stream_mailbox_overflow_path must be configured as drop or notify"
  end

  test "normalize accepts atom-keyed runtime override maps" do
    assert Overrides.normalize!(%{
             cleanup_allowed_memory_growth_mb: 128,
             stream_mailbox_backpressure_behavior: "none"
           }) == %{
             allowed_memory_growth_mb: 128,
             stream_mailbox_backpressure_behavior: :none
           }
  end

  test "apply updates runtime fields and keeps cleanup policy in sync" do
    config = %{
      parallel_child_count: 3,
      repeat_count: 1,
      stream_mailbox_capacity: 1_000,
      stream_mailbox_overflow_path: :drop,
      stream_mailbox_backpressure_threshold: 800,
      stream_mailbox_backpressure_behavior: :notify,
      stream_mailbox_backpressure_delay_ms: 10,
      allowed_memory_growth_mb: 64,
      stale_cleanup_timeout_ms: 30_000,
      operation_timeout_ms: 120_000,
      stream_subscription_cleanup_timeout_ms: 10_000,
      pane_state_retention_ms: 300_000,
      cleanup_policy: %{
        allowed_memory_growth_mb: 64,
        stale_cleanup_timeout_ms: 30_000,
        stream_subscription_cleanup_timeout_ms: 10_000,
        pane_state_retention_ms: 300_000
      }
    }

    config =
      Overrides.apply(config, %{
        parallel_child_count: 8,
        operation_timeout_ms: 90_000,
        pane_state_retention_ms: 700_000
      })

    assert config.parallel_child_count == 8
    assert config.operation_timeout_ms == 90_000
    assert config.pane_state_retention_ms == 700_000
    assert config.cleanup_policy.pane_state_retention_ms == 700_000
  end
end
