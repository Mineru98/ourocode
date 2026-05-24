defmodule Ourocode.Runtime.ChildPaneSteeringTargetTest do
  use ExUnit.Case, async: true

  alias Ourocode.Json
  alias Ourocode.Runtime.ChildPaneSteeringTarget

  test "fetches pane-directed steering messages with atom or string type keys" do
    assert {:ok, %{type: :pane_directed_steering_message}} =
             ChildPaneSteeringTarget.fetch_message(%{
               steering_message: %{type: :pane_directed_steering_message}
             })

    assert {:ok, %{"type" => "pane_directed_steering_message"}} =
             ChildPaneSteeringTarget.fetch_message(%{
               "steering_message" => %{"type" => "pane_directed_steering_message"}
             })

    assert ChildPaneSteeringTarget.fetch_message(%{}) ==
             {:error, :missing_pane_directed_steering_message}
  end

  test "resolves focused child pane from context focus state before stale message target" do
    input_event = %{steering_target_pane_id: "child-session:stale"}
    message = %{target_pane_id: "child-session:stale"}

    pane_model = %{
      panes: %{
        "child-session:bravo" => %{id: "child-session:bravo", kind: :child_session},
        "child-session:stale" => %{id: "child-session:stale", kind: :child_session}
      }
    }

    assert {:ok, %{id: "child-session:bravo"}} =
             ChildPaneSteeringTarget.resolve_pane(input_event, message, pane_model, %{
               focus_state: %{focused_pane: "child-session:bravo"}
             })
  end

  test "rejects missing, unknown, and non-child pane targets" do
    assert ChildPaneSteeringTarget.resolve_pane(%{}, %{}, %{panes: %{}}, %{}) ==
             {:error, :missing_steering_target_pane_id}

    assert ChildPaneSteeringTarget.resolve_pane(
             %{steering_target_pane_id: "missing"},
             %{},
             %{panes: %{}},
             %{}
           ) == {:error, {:focused_child_pane_not_found, "missing"}}

    assert ChildPaneSteeringTarget.resolve_pane(
             %{steering_target_pane_id: "parent"},
             %{},
             %{panes: %{"parent" => %{id: "parent", kind: :parent}}},
             %{}
           ) == {:error, {:focused_pane_is_not_child, "parent", :parent}}
  end

  test "serializes steering message using resolved pane metadata" do
    input_event = %{
      steering_text: "continue here",
      event_seq: 11,
      task_request_id: :task_1,
      steering_target: :child,
      focused_pane: "child-session:bravo"
    }

    message = %{
      content: "message content",
      target_pane_id: "stale-pane",
      target_session_id: "stale-session",
      target_kind: :parent_session
    }

    pane = %{id: "child-session:bravo", kind: :child_session, child_id: "bravo"}

    assert {:ok, serialized, decoded} =
             ChildPaneSteeringTarget.serialize(input_event, message, pane)

    assert {:ok, wire} = Json.decode(serialized)

    assert decoded.target_pane_id == "child-session:bravo"
    assert decoded.target_session_id == "bravo"
    assert decoded.target_kind == "child_session"
    assert decoded.task_request_id == "task_1"
    assert wire["target_pane_id"] == "child-session:bravo"
    assert wire["source_event_seq"] == 11
  end
end
