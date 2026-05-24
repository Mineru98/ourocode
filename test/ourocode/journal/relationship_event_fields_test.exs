defmodule Ourocode.Journal.RelationshipEventFieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.RelationshipEventFields, as: Fields

  test "normalizes relationship top-level string keys" do
    event =
      Fields.normalize(%{
        "event_seq" => "2",
        "parent_call_id" => "parent-1",
        "acknowledged_stream_cursor" => %{"offset" => 1},
        "pane_state" => %{"child_id" => "nested-child"}
      })

    assert event.event_seq == "2"
    assert event.parent_call_id == "parent-1"
    assert event.acknowledged_stream_cursor == %{"offset" => 1}
    assert event.pane_state == %{"child_id" => "nested-child"}
  end

  test "reads trimmed strings, integers, and maps" do
    event =
      Fields.normalize(%{
        "child_id" => " child-1 ",
        "occurred_at_ms" => " 123 ",
        "external_ids" => %{"session_id" => "session-1"}
      })

    assert Fields.string_value(event, :child_id) == "child-1"
    assert Fields.integer_value(event, :occurred_at_ms) == 123
    assert Fields.map_value(event, :external_ids, %{}) == %{"session_id" => "session-1"}
  end

  test "rejects malformed integers and non-map map values" do
    event = Fields.normalize(%{"occurred_at_ms" => "123ms", "external_ids" => "bad"})

    assert Fields.integer_value(event, :occurred_at_ms) == nil
    assert Fields.map_value(event, :external_ids, %{default: true}) == %{default: true}
  end

  test "normalizes supported transports" do
    assert Fields.transport(%{transport: :stdio}) == {:ok, :stdio}
    assert Fields.transport(%{transport: "streamable_http"}) == {:ok, :streamable_http}
    assert Fields.transport(%{transport: "sse"}) == {:ok, :sse}
    assert Fields.transport(%{transport: "unknown"}) == {:error, :invalid_transport}
  end
end
