defmodule Ourocode.Runtime.ChildSessionActionDispatchTest do
  use ExUnit.Case, async: true

  alias Ourocode.Json
  alias Ourocode.Runtime.{ChildSessionActionDispatch, FocusState}

  test "dispatch_interrupt sends a focused child interrupt request" do
    {focus_state, pane_model} = focused_child_fixture()

    dispatcher = fn pane, serialized_request, context ->
      send(self(), {:interrupted, pane, serialized_request, context})
      {:ok, :interrupted}
    end

    assert {:ok,
            %{
              pane: %{id: "child-session:bravo"},
              serialized_request: serialized_request,
              decoded_request: decoded_request,
              delivery_result: :interrupted
            }} =
             ChildSessionActionDispatch.dispatch_interrupt(
               %{command: "/interrupt", args: ["stop"], event_seq: 5},
               focus_state: focus_state,
               pane_model: pane_model,
               child_session_interrupt_dispatcher: dispatcher,
               context: %{journal_scope: "interrupt-test"}
             )

    assert_receive {:interrupted, %{id: "child-session:bravo"}, ^serialized_request,
                    %{journal_scope: "interrupt-test", decoded_request: ^decoded_request}}

    assert {:ok, wire_request} = Json.decode(serialized_request)
    assert wire_request["type"] == "child_session_interrupt_request"
    assert wire_request["action"] == "interrupt"
    assert wire_request["target_pane_id"] == "child-session:bravo"
    assert wire_request["target_session_id"] == "bravo"
    assert wire_request["reason"] == "stop"
    assert wire_request["source_event_seq"] == 5
  end

  test "dispatch_cancel sends a focused child cancel request" do
    {focus_state, pane_model} = focused_child_fixture()

    assert {:ok, %{serialized_request: serialized_request, delivery_result: :ok}} =
             ChildSessionActionDispatch.dispatch_cancel(
               %{command: "/cancel", args: [], event_seq: 6},
               focus_state: focus_state,
               pane_model: pane_model,
               child_session_cancel_dispatcher: fn _pane, _request -> :ok end
             )

    assert {:ok, wire_request} = Json.decode(serialized_request)
    assert wire_request["type"] == "child_session_cancel_request"
    assert wire_request["action"] == "cancel"
    assert wire_request["target_pane_id"] == "child-session:bravo"
    assert wire_request["reason"] == "user_requested_cancel"
  end

  test "dispatch rejects unsupported actions and invalid dispatcher results" do
    {focus_state, pane_model} = focused_child_fixture()

    assert ChildSessionActionDispatch.dispatch_interrupt(
             %{command: "/unknown"},
             focus_state: focus_state,
             pane_model: pane_model
           ) == {:error, {:unsupported_builtin_action, "/unknown"}}

    assert ChildSessionActionDispatch.dispatch_cancel(
             %{command: "/cancel"},
             focus_state: focus_state,
             pane_model: pane_model,
             child_session_cancel_dispatcher: fn _pane, _request -> :unexpected end
           ) == {:error, {:invalid_child_session_cancel_dispatch_result, :unexpected}}
  end

  defp focused_child_fixture do
    pane_model = %{
      panes: %{
        "child-session:bravo" => %{
          id: "child-session:bravo",
          kind: :child_session,
          child_id: "bravo",
          transport: :stdio
        }
      },
      open: ["child-session:bravo"]
    }

    {:ok, focus_state, _event} =
      FocusState.focus_pane(FocusState.new(), "child-session:bravo", pane_model)

    {focus_state, pane_model}
  end
end
