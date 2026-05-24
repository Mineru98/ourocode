defmodule Ourocode.Journal.CleanupEventFieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.CleanupEventFields, as: Fields

  test "normalizes top-level string keys while preserving nested payload keys" do
    event =
      Fields.normalize(%{
        "event_seq" => "7",
        "runtime_source" => "codex",
        "external_ids" => %{"session_id" => "session-1", "thread_id" => "thread-1"},
        "pane_state" => %{"child_id" => "nested-child"}
      })

    assert event.event_seq == "7"
    assert event.runtime_source == "codex"
    assert event.external_ids == %{"session_id" => "session-1", "thread_id" => "thread-1"}
    assert event.pane_state == %{"child_id" => "nested-child"}
  end

  test "reads strings, integers, atoms, and maps through normalized accessors" do
    event =
      Fields.normalize(%{
        "child_id" => 123,
        "occurred_at_ms" => "456",
        "cleanup_reason" => "idle_timeout",
        "external_ids" => %{"session_id" => "session-1"}
      })

    assert Fields.string_value(event, :child_id) == "123"
    assert Fields.integer_value(event, :occurred_at_ms) == 456
    assert Fields.atom_value(event, :cleanup_reason) == :idle_timeout
    assert Fields.map_value(event, :external_ids, %{}) == %{"session_id" => "session-1"}
  end

  test "rejects unsupported atom strings and malformed integers" do
    event = Fields.normalize(%{"cleanup_reason" => "unknown", "occurred_at_ms" => "12ms"})

    assert Fields.atom_value(event, :cleanup_reason) == nil
    assert Fields.integer_value(event, :occurred_at_ms) == nil
  end

  test "normalizes supported transports and resolves session id from external ids" do
    event = Fields.normalize(%{"transport" => "sse", "external_ids" => %{"session_id" => "s-1"}})

    assert Fields.transport(event) == :sse
    assert Fields.session_id(event) == "s-1"

    assert Fields.transport(%{transport: :streamable_http}) == :streamable_http
    assert Fields.transport(%{transport: "unknown"}) == nil
  end
end
