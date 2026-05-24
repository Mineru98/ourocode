defmodule Ourocode.MCP.Transport.StreamableHTTP.LifecycleRecordTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.StreamableHTTP.LifecycleRecord

  test "classifies lifecycle record types from type and event_type fields" do
    assert LifecycleRecord.type(%{"type" => " parent_call_result "}) ==
             {:ok, :parent_call_result}

    assert LifecycleRecord.type(%{"event_type" => "transport_failed"}) ==
             {:ok, :transport_failed}

    assert LifecycleRecord.type(%{"type" => "unknown"}) == :error
    assert LifecycleRecord.type(%{"type" => :parent_call_result}) == :error
  end

  test "keeps only lifecycle attributes and preserves the raw record" do
    record = %{
      "type" => "parent_call_result",
      "request_id" => "call-1",
      "payload" => %{"token" => "done"},
      "result" => %{"ok" => true},
      "ignored" => "metadata"
    }

    assert LifecycleRecord.attrs(record) == %{
             raw_event: record,
             request_id: "call-1",
             payload: %{"token" => "done"},
             result: %{"ok" => true}
           }
  end

  test "distinguishes lifecycle result envelopes from opaque typed payloads" do
    assert LifecycleRecord.result_envelope?(%{
             "type" => "parent_call_result",
             "payload" => %{"token" => "done"},
             "result" => %{"ok" => true}
           })

    refute LifecycleRecord.result_envelope?(%{
             "type" => "parent_call_result",
             "payload" => %{"token" => "done"}
           })
  end

  test "orders lifecycle error candidates from most specific to broadest" do
    lifecycle_event = %{"type" => "parent_call_failed", "error" => %{"reason" => "nested"}}
    event = %{"type" => "transport_failed", "error" => %{"reason" => "event"}}
    data = %{"lifecycle_event" => lifecycle_event, "event" => event}
    error = %{"code" => -32_000, "data" => data}

    assert LifecycleRecord.error_candidates(error) == [lifecycle_event, event, data, error]
  end
end
