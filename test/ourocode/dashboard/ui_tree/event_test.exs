defmodule Ourocode.Dashboard.UITree.EventTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.UITree.Event

  test "normalizes restored string-key lifecycle events" do
    assert Event.normalize(%{
             "type" => "child_pane_registered",
             "event_seq" => "12",
             "pane_id" => "pane-1",
             "child_id" => 123,
             "transport" => "streamable_http",
             "parent_call_id" => "parent-1",
             "runtime_source" => :codex,
             "external_ids" => %{"session_id" => "session-1"},
             "created_at_ms" => "100",
             "updated_at_ms" => "101"
           }) == %{
             type: :child_pane_registered,
             event_seq: 12,
             pane_id: "pane-1",
             child_id: "123",
             transport: :streamable_http,
             parent_call_id: "parent-1",
             runtime_source: "codex",
             external_ids: %{"session_id" => "session-1"},
             created_at_ms: 100,
             updated_at_ms: 101
           }
  end

  test "drops unknown lifecycle type and malformed integer values" do
    assert Event.normalize(%{"type" => "unknown", "event_seq" => "12ms"}) == %{
             external_ids: %{}
           }
  end

  test "detects child stream events from external ids and nested payloads" do
    assert Event.child_stream_event?(%{external_ids: %{"childID" => "child-1"}})
    assert Event.child_stream_event?(%{payload: %{"child_id" => "child-1"}})
    assert Event.child_stream_event?(%{notification: %{"params" => %{"childID" => "child-1"}}})

    assert Event.child_stream_event?(%{
             raw_event: %{"data" => %{"params" => %{"childID" => "c"}}}
           })

    refute Event.child_stream_event?(%{external_ids: %{"session_id" => "session-1"}})
  end
end
