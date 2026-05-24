defmodule Ourocode.Config.CleanupPolicyTest do
  use ExUnit.Case, async: true

  alias Ourocode.Config.CleanupPolicy

  test "validate accepts canonical atom keys and string keys" do
    assert CleanupPolicy.validate(%{
             "allowed-memory-growth-mb" => 96,
             "stale-cleanup-timeout-ms" => 40_000,
             "stream-subscription-cleanup-timeout-ms" => 11_000,
             "pane-state-retention-ms" => 450_000
           }) ==
             {:ok,
              %{
                allowed_memory_growth_mb: 96,
                stale_cleanup_timeout_ms: 40_000,
                stream_subscription_cleanup_timeout_ms: 11_000,
                pane_state_retention_ms: 450_000
              }}
  end

  test "validate rejects non-map cleanup policy values" do
    assert CleanupPolicy.validate("bad") ==
             {:error, "cleanup_policy must be configured as a map, got: \"bad\""}
  end

  test "validate rejects unknown, missing, and non-positive policy values" do
    assert {:error, unknown_message} =
             %{
               allowed_memory_growth_mb: 96,
               stale_cleanup_timeout_ms: 40_000,
               stream_subscription_cleanup_timeout_ms: 11_000,
               pane_state_retention_ms: 450_000,
               pane_state_limit_ms: 1
             }
             |> CleanupPolicy.validate()

    assert unknown_message =~ "cleanup_policy contains unsupported keys"
    assert unknown_message =~ "pane_state_limit_ms"

    assert {:error, missing_message} =
             %{
               allowed_memory_growth_mb: 96,
               stale_cleanup_timeout_ms: 40_000,
               stream_subscription_cleanup_timeout_ms: 11_000
             }
             |> CleanupPolicy.validate()

    assert missing_message =~ "cleanup_policy is missing required keys"
    assert missing_message =~ "pane_state_retention_ms"

    assert {:error, value_message} =
             %{
               allowed_memory_growth_mb: 96,
               stale_cleanup_timeout_ms: 0,
               stream_subscription_cleanup_timeout_ms: 11_000,
               pane_state_retention_ms: 450_000
             }
             |> CleanupPolicy.validate()

    assert value_message =~
             "cleanup_policy.stale_cleanup_timeout_ms must be configured as a positive integer"
  end
end
