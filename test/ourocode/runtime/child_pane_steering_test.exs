defmodule Ourocode.Runtime.ChildPaneSteeringTest do
  use ExUnit.Case, async: true

  alias Ourocode.Json
  alias Ourocode.Runtime.ChildPaneSteering

  test "dispatch resolves current focused child pane and serializes steering message" do
    input_event = %{
      steering_target: :child,
      steering_text: "continue here",
      event_seq: 11,
      steering_message: %{
        type: :pane_directed_steering_message,
        target_pane_id: "child-session:stale",
        target_session_id: "stale",
        target_kind: :parent_session,
        content: "continue here"
      }
    }

    pane_model = %{
      panes: %{
        "child-session:bravo" => %{
          id: "child-session:bravo",
          kind: :child_session,
          child_id: "bravo"
        },
        "child-session:stale" => %{
          id: "child-session:stale",
          kind: :child_session,
          child_id: "stale"
        }
      }
    }

    dispatcher = fn pane, serialized_message, context ->
      send(self(), {:delivered, pane, serialized_message, context})
      :ok
    end

    assert {:ok,
            %{
              pane: %{id: "child-session:bravo"},
              serialized_message: serialized_message,
              decoded_message: decoded_message,
              delivery_result: :ok
            }} =
             ChildPaneSteering.dispatch(input_event,
               pane_model: pane_model,
               child_pane_dispatcher: dispatcher,
               context: %{focus_state: %{focused_pane: "child-session:bravo"}}
             )

    assert_receive {:delivered, %{id: "child-session:bravo"}, ^serialized_message,
                    %{decoded_message: ^decoded_message}}

    assert {:ok, wire_message} = Json.decode(serialized_message)
    assert wire_message["target_pane_id"] == "child-session:bravo"
    assert wire_message["target_session_id"] == "bravo"
    assert wire_message["target_kind"] == "child_session"
    assert wire_message["source_event_seq"] == 11
  end

  test "dispatch rejects missing child target and invalid dispatch results" do
    assert ChildPaneSteering.dispatch(%{steering_target: :parent}, []) ==
             {:error, {:unsupported_steering_target, :parent}}

    input_event = %{
      steering_target: :child,
      steering_target_pane_id: "child-session:bravo",
      steering_message: %{type: :pane_directed_steering_message, content: "hello"}
    }

    assert ChildPaneSteering.dispatch(input_event,
             pane_model: %{panes: %{}},
             child_pane_dispatcher: fn _pane, _message -> :ok end
           ) == {:error, {:focused_child_pane_not_found, "child-session:bravo"}}

    assert ChildPaneSteering.dispatch(input_event,
             pane_model: %{
               panes: %{
                 "child-session:bravo" => %{id: "child-session:bravo", kind: :child_session}
               }
             },
             child_pane_dispatcher: fn _pane, _message -> :unexpected end
           ) == {:error, {:invalid_child_pane_dispatch_result, :unexpected}}
  end
end
