defmodule Ourocode.Journal.RelationshipEventTypeTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.RelationshipEventType

  test "category classifies pane lifecycle events" do
    assert RelationshipEventType.category(%{type: :child_pane_registered}) ==
             {:ok, :pane_lifecycle, :child_pane_registered}

    assert RelationshipEventType.category(%{"event_type" => "child_pane_completed"}) ==
             {:ok, :pane_lifecycle, :child_pane_completed}
  end

  test "category classifies runtime relationship events" do
    assert RelationshipEventType.category(%{type: :parent_call_event}) ==
             {:ok, :runtime_relationship, :parent_call_event}

    assert RelationshipEventType.category(%{event_type: " parent_call_result "}) ==
             {:ok, :runtime_relationship, :parent_call_result}
  end

  test "category ignores unknown or missing relationship types" do
    assert RelationshipEventType.category(%{type: :transport_cleanup}) == :error
    assert RelationshipEventType.category(%{type: "unknown"}) == :error
    assert RelationshipEventType.category(%{}) == :error
  end
end
