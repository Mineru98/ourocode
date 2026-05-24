defmodule Ourocode.Journal.RelationshipPaneStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.RelationshipPaneState

  test "merges pane snapshots while preserving latest scalar fields" do
    assert RelationshipPaneState.merge(
             %{"title" => "Old", "last_event_seq" => 1},
             %{"title" => "New", "status" => "working", "last_event_seq" => 2}
           ) == %{
             "title" => "New",
             "status" => "working",
             "last_event_seq" => 2
           }
  end

  test "dedupes stream entries by child event id across atom and string keys" do
    existing = %{
      stream_entries: [
        %{child_event_id: "event-1", token: "hello"},
        %{child_event_id: "event-2", token: "world"}
      ]
    }

    incoming = %{
      "stream_entries" => [
        %{"child_event_id" => "event-1", "token" => "hello again"},
        %{"child_event_id" => "event-3", "token" => "!"}
      ]
    }

    assert %{
             stream_entries: [
               %{child_event_id: "event-1", token: "hello"},
               %{child_event_id: "event-2", token: "world"},
               %{"child_event_id" => "event-3", "token" => "!"}
             ]
           } = RelationshipPaneState.merge(existing, incoming)
  end

  test "dedupes stream entries by replay payload when child event id is absent" do
    existing = %{
      stream_entries: [
        %{event_seq: 1, runtime_seq: 1, token: "alpha"},
        %{event_seq: 2, runtime_seq: 2, token: "beta"}
      ]
    }

    incoming = %{
      stream_entries: [
        %{"event_seq" => 1, "runtime_seq" => 1, "token" => "alpha"},
        %{event_seq: 3, runtime_seq: 3, token: "gamma"}
      ]
    }

    assert %{
             stream_entries: [
               %{event_seq: 1, runtime_seq: 1, token: "alpha"},
               %{event_seq: 2, runtime_seq: 2, token: "beta"},
               %{event_seq: 3, runtime_seq: 3, token: "gamma"}
             ]
           } = RelationshipPaneState.merge(existing, incoming)
  end

  test "handles nil pane snapshots as empty maps" do
    assert RelationshipPaneState.merge(nil, %{"status" => "working"}) == %{"status" => "working"}
    assert RelationshipPaneState.merge(%{"status" => "working"}, nil) == %{"status" => "working"}
  end
end
