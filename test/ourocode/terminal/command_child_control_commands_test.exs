defmodule Ourocode.Terminal.CommandChildControlCommandsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.FocusState
  alias Ourocode.Terminal.CommandChildControlCommands
  alias Ourocode.Json

  test "handles focused child control actions only" do
    assert CommandChildControlCommands.handles?(:interrupt_focused_child)
    assert CommandChildControlCommands.handles?(:cancel_focused_child)
    refute CommandChildControlCommands.handles?(:show_status)
    refute CommandChildControlCommands.handles?(:unknown)
  end

  test "dispatch_options overlays current focus and pane model" do
    focus_state = FocusState.new()
    pane_model = %{panes: %{}, open: []}

    options =
      CommandChildControlCommands.dispatch_options(%{
        command_dispatch_options: %{context: %{journal_scope: "test"}, focus_state: :stale},
        focus_state: focus_state,
        pane_model: pane_model
      })

    assert options.context == %{journal_scope: "test"}
    assert options.focus_state == focus_state
    assert options.pane_model == pane_model
  end

  test "dispatch interrupt sends command through the focused child dispatcher" do
    parent = self()

    state =
      state(%{
        child_session_interrupt_dispatcher: fn pane, serialized_request, context ->
          send(parent, {:interrupt, pane, serialized_request, context})
          {:ok, :interrupted}
        end
      })

    assert {:ok, %{delivery_result: :interrupted}} =
             CommandChildControlCommands.dispatch(
               :interrupt_focused_child,
               command_event(:interrupt_focused_child, "/interrupt", ["stop"]),
               state
             )

    assert_receive {:interrupt, %{id: "child-session:alpha"}, serialized_request, context}
    assert is_binary(serialized_request)
    assert context.decoded_request.action == "interrupt"
  end

  test "dispatch cancel sends command through the focused child dispatcher" do
    parent = self()

    state =
      state(%{
        child_session_cancel_dispatcher: fn pane, serialized_request, context ->
          send(parent, {:cancel, pane, serialized_request, context})
          {:ok, :cancelled}
        end
      })

    assert {:ok, %{delivery_result: :cancelled}} =
             CommandChildControlCommands.dispatch(
               :cancel_focused_child,
               command_event(:cancel_focused_child, "/cancel", ["user", "cancelled"]),
               state
             )

    assert_receive {:cancel, %{id: "child-session:alpha"}, serialized_request, context}
    assert is_binary(serialized_request)
    assert context.decoded_request.action == "cancel"
    assert context.decoded_request.type == "child_session_cancel_request"
    assert context.decoded_request.target_pane_id == "child-session:alpha"
    assert context.decoded_request.target_session_id == "alpha"
    assert context.decoded_request.reason == "user cancelled"

    assert {:ok, wire_request} = Json.decode(serialized_request)
    assert wire_request["type"] == "child_session_cancel_request"
    assert wire_request["action"] == "cancel"
    assert wire_request["target_pane_id"] == "child-session:alpha"
    assert wire_request["target_session_id"] == "alpha"
    assert wire_request["source_command"] == "/cancel"
    assert wire_request["source_args"] == ["user", "cancelled"]
    assert wire_request["reason"] == "user cancelled"
  end

  test "dispatch cancel without focused child returns idle guidance" do
    {:ok, output} = StringIO.open("")

    assert {:ok,
            %{
              cancel: %{
                status: :idle,
                message: "No active work to cancel.",
                next_actions: ["ooo pm <goal>", "/agents", "/verify"]
              }
            }} =
             CommandChildControlCommands.dispatch(
               :cancel_focused_child,
               command_event(:cancel_focused_child, "/cancel", []),
               %{
                 output: output,
                 focus_state: FocusState.new(),
                 pane_model: %{panes: %{}, open: []}
               }
             )

    {_input, text} = StringIO.contents(output)
    StringIO.close(output)

    assert text =~ "cancel: no active work"
    assert text =~ "nothing is waiting for cancellation"
    assert text =~ "ooo pm <goal>"
  end

  defp command_event(action, command, args) do
    %{
      type: :slash_command_submitted,
      command: command,
      args: args,
      run_spec: %{kind: :builtin_action, action: action}
    }
  end

  defp state(dispatch_options) do
    pane_model = %{
      panes: %{
        :parent => %{id: :parent, kind: :parent_session, session_id: "parent"},
        "child-session:alpha" => %{
          id: "child-session:alpha",
          kind: :child_session,
          child_id: "alpha"
        }
      },
      open: [:parent, "child-session:alpha"]
    }

    {:ok, focus_state, _event} =
      FocusState.focus_pane(FocusState.new(), "child-session:alpha", pane_model)

    %{
      command_dispatch_options: Map.put(dispatch_options, :context, %{source: :test}),
      focus_state: focus_state,
      pane_model: pane_model
    }
  end
end
