defmodule Ourocode.MCP.Transport.Stdio.RawEventTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.Stdio.RawEvent

  test "builds stdio raw context with session and payload fingerprint" do
    raw_payload = ~s({"jsonrpc":"2.0","id":"1"})
    expected_ref = "sha256:" <> Base.encode16(:crypto.hash(:sha256, raw_payload), case: :lower)

    context =
      RawEvent.context(
        %{
          port: :not_a_port,
          parent_call_id: "parent-1",
          external_ids: %{"session_id" => "session-1"}
        },
        :inbound,
        raw_payload,
        123
      )

    assert context == %{
             transport: :stdio,
             transport_type: :stdio,
             process_identifier: %{port: ":not_a_port", os_pid: nil},
             session_identifier: "session-1",
             stream_direction: :inbound,
             timestamp_ms: 123,
             raw_payload_ref: expected_ref
           }
  end

  test "context falls back to native session id and parent call id" do
    assert %{session_identifier: "native-1"} =
             RawEvent.context(
               %{parent_call_id: "parent-1", external_ids: %{native_session_id: "native-1"}},
               :outbound,
               %{request: true},
               123
             )

    assert %{session_identifier: "parent-1"} =
             RawEvent.context(
               %{parent_call_id: "parent-1", external_ids: %{}},
               :outbound,
               %{request: true},
               123
             )
  end

  test "annotates lifecycle raw_event without replacing decoded payload fields" do
    event =
      LifecycleEvent.new(
        :parent_call_result,
        Map.merge(base_event_attrs(), %{raw_event: %{"id" => "1"}})
      )

    assert %LifecycleEvent{raw_event: %{"id" => "1", transport: :stdio}} =
             RawEvent.annotate_lifecycle(event, %{transport: :stdio})
  end

  test "canonical_journal_event compacts nils and canonicalizes stdio decode failures" do
    event = %{
      type: :transport_decode_failed,
      optional: nil,
      error: {:malformed_stdout_line, {:expected_object_key, "{bad"}},
      error_details: %{reason: {:expected_object_key, "{bad"}}
    }

    assert RawEvent.canonical_journal_event(event) == %{
             type: :transport_decode_failed,
             error: {:malformed_stdout_line, :expected_object_key},
             error_details: %{reason: :expected_object_key}
           }
  end

  test "canonical_journal_event keeps only replayable notification fields" do
    event =
      LifecycleEvent.new(
        :parent_call_event,
        Map.merge(base_event_attrs(), %{
          notification: %{"id" => "n-1", "method" => "progress", "extra" => "drop"}
        })
      )

    assert %{notification: %{"id" => "n-1", "method" => "progress"}} =
             RawEvent.canonical_journal_event(event)
  end

  defp base_event_attrs do
    %{
      event_seq: 1,
      transport: :stdio,
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      external_ids: %{},
      occurred_at_ms: 123
    }
  end
end
