defmodule Ourocode.Dashboard.ChildSessionStreamEntryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionStreamEntry

  test "entries_for_event normalizes token delta content and runtime sequence" do
    event = %{
      event_seq: 10,
      type: :parent_call_event,
      parent_call_id: "parent-1",
      runtime_source: "opencode",
      transport: :sse,
      external_ids: %{"childID" => "child-1"},
      notification: %{
        "params" => %{
          "childID" => "child-1",
          "seq" => "7",
          "token" => "hello",
          "delta" => 42,
          "content" => true
        }
      }
    }

    assert [entry] = ChildSessionStreamEntry.entries_for_event(event, 10, 1_234)

    assert entry.event_seq == 10
    assert entry.runtime_seq == 7
    assert entry.type == :parent_call_event
    assert entry.token == "hello"
    assert entry.delta == "42"
    assert entry.content == "true"
    assert entry.occurred_at_ms == 1_234
    assert entry.payload["childID"] == "child-1"
    assert is_binary(entry.child_event_id)
  end

  test "entries_for_event preserves explicit child event identities" do
    event = %{
      child_event_id: "child-event:explicit",
      params: %{seq: 1, token: "hello"}
    }

    assert [%{child_event_id: "child-event:explicit"}] =
             ChildSessionStreamEntry.entries_for_event(event, 1, 10)
  end

  test "entries_for_event emits media placeholders for image-like payload items" do
    event = %{
      params: %{
        seq: 1,
        token: "see",
        images: [
          %{"type" => "image/png"},
          %{"url" => "https://example.test/image.jpg"},
          %{"type" => "text/plain"}
        ]
      }
    }

    assert [%{media_placeholders: ["[Image #1]", "[Image #2]"]}] =
             ChildSessionStreamEntry.entries_for_event(event, 1, 10)
  end

  test "entries_for_event supports cursorless opencode child stream payloads" do
    event = %{
      type: :parent_call_event,
      runtime_source: "opencode",
      raw_event: %{
        "data" => %{
          "params" => %{"childID" => "child-1"}
        }
      }
    }

    assert [entry] = ChildSessionStreamEntry.entries_for_event(event, 2, 20)
    assert entry.payload["childID"] == "child-1"
  end

  test "entries_for_event supports cursorless ouroboros child stream payloads" do
    event = %{
      type: :parent_call_event,
      runtime_source: "ouroboros",
      notification: %{
        "params" => %{"child_id" => "job-1", "parent_call_id" => "parent-1"}
      }
    }

    assert [entry] = ChildSessionStreamEntry.entries_for_event(event, 3, 30)
    assert entry.payload["child_id"] == "job-1"
  end

  test "entries_for_event supports cursorless ouroboros atom-key child payloads" do
    event = %{
      type: :parent_call_event,
      runtime_source: "ouroboros",
      params: %{child_id: "job-2", parent_call_id: "parent-2"}
    }

    assert [entry] = ChildSessionStreamEntry.entries_for_event(event, 4, 40)
    assert entry.payload[:child_id] == "job-2"
  end

  test "entries_for_event still drops cursorless payloads from other runtimes" do
    event = %{
      type: :parent_call_event,
      runtime_source: "codex",
      params: %{"child_id" => "child-9"}
    }

    assert ChildSessionStreamEntry.entries_for_event(event, 5, 50) == []
  end

  test "entries_for_event ignores events without stream payloads" do
    assert ChildSessionStreamEntry.entries_for_event(%{type: :parent_call_started}, 1, 10) == []
  end
end
