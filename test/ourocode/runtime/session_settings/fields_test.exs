defmodule Ourocode.Runtime.SessionSettings.FieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.SessionSettings.Fields

  test "normalizes string and dashed keys to session setting atoms" do
    assert Fields.normalize_keys(%{
             "runtime-source" => "runtime",
             "stream_mailbox_capacity" => 8,
             "unknown-key" => true
           }) == %{
             :runtime_source => "runtime",
             :stream_mailbox_capacity => 8,
             "unknown-key" => true
           }
  end

  test "validates non-empty strings" do
    assert Fields.non_empty_string(%{}, :runtime_source, "synthetic", "runtime_source") ==
             {:ok, "synthetic"}

    assert Fields.optional_non_empty_string(
             %{session_id: " session-1 "},
             :session_id,
             "session_id"
           ) ==
             {:ok, "session-1"}

    assert {:error, {:invalid_session_settings, message}} =
             Fields.optional_non_empty_string(%{session_id: ""}, :session_id, "session_id")

    assert message =~ "session_id must be a non-empty string"
  end

  test "normalizes external ids to string keys and rejects unsupported values" do
    assert Fields.external_ids(%{
             external_ids: %{:session_id => "session-1", "attempt" => 2, "active" => true}
           }) ==
             {:ok, %{"session_id" => "session-1", "attempt" => 2, "active" => true}}

    assert {:error, {:invalid_session_settings, message}} =
             Fields.external_ids(%{external_ids: %{"session_id" => %{}}})

    assert message =~ "external_ids.session_id must be a string, number, boolean, or nil"
  end

  test "normalizes enums and drain interval aliases" do
    assert Fields.transport(%{transport: "streamable-http"}) == {:ok, :streamable_http}

    assert Fields.overflow_path(%{stream_mailbox_overflow_path: "notify"}, :drop) ==
             {:ok, :notify}

    assert Fields.backpressure_behavior(
             %{stream_mailbox_backpressure_behavior: "delay"},
             :none
           ) == {:ok, :delay}

    assert Fields.cleanup_action(%{stream_cleanup_action: "mark-stale"}) == {:ok, :mark_stale}
    assert Fields.drain_interval(%{stream_mailbox_drain_interval_ms: "manual"}) == {:ok, :manual}
    assert Fields.drain_interval(%{stream_mailbox_drain_interval_ms: 0}) == {:ok, 0}
  end

  test "validates mailbox bounds and passthrough fields" do
    assert :ok = Fields.validate_mailbox_bounds(4, 4)

    assert {:error, {:invalid_session_settings, message}} = Fields.validate_mailbox_bounds(3, 4)
    assert message =~ "stream_mailbox_backpressure_threshold"

    assert Fields.append_passthrough([runtime_source: "runtime"], %{
             id: "session-id",
             stream_mailbox_overflow_target: self()
           }) == [
             stream_mailbox_overflow_target: self(),
             id: "session-id",
             runtime_source: "runtime"
           ]
  end
end
