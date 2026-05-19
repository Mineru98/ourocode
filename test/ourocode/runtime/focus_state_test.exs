defmodule Ourocode.Runtime.FocusStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.FocusState

  test "tracks the currently focused pane after a valid pane id is requested" do
    pane_model = %{
      panes: %{
        parent: %{id: :parent, kind: :parent_session},
        children: %{id: :children, kind: :child_sessions}
      },
      open: [:parent, :children]
    }

    assert {:ok, focus_state, event} =
             FocusState.focus_pane(FocusState.new(), :children, pane_model, occurred_at_ms: 1_700)

    assert focus_state.focused_pane == :children
    assert focus_state.previous_focused_pane == :task_prompt
    assert focus_state.steering_target == :child
    assert focus_state.steering_target_pane_id == :children
    assert focus_state.steering_target_session_id == nil
    assert focus_state.steering_target_kind == :child_sessions
    assert focus_state.route == :focused_pane
    assert focus_state.focused_at_ms == 1_700

    assert event == %{
             type: :focus_state_updated,
             event_type: :focus_state_updated,
             source: :pane_model,
             requested_pane_id: :children,
             previous_focused_pane: :task_prompt,
             focused_pane: :children,
             steering_target: :child,
             steering_target_pane_id: :children,
             steering_target_session_id: nil,
             steering_target_kind: :child_sessions,
             occurred_at_ms: 1_700
           }

    assert [^event] = focus_state.history
  end

  test "accepts string requests for atom pane ids without creating atoms" do
    pane_model = %{panes: %{parent: %{id: :parent}}, open: [:parent]}

    assert {:ok, focus_state, event} =
             FocusState.focus_pane(FocusState.new(), "parent", pane_model)

    assert focus_state.focused_pane == :parent
    assert event.focused_pane == :parent
    assert event.steering_target == :parent
  end

  test "accepts dynamic string pane ids when they are present in the pane model" do
    pane_model = %{
      panes: %{
        child: %{id: "child-session:alpha", kind: :child_session}
      },
      open: ["child-session:alpha"]
    }

    assert {:ok, focus_state, event} =
             FocusState.focus_pane(FocusState.new(), "child-session:alpha", pane_model)

    assert focus_state.focused_pane == "child-session:alpha"
    assert event.steering_target == :child
    assert focus_state.steering_target_pane_id == "child-session:alpha"
    assert focus_state.steering_target_session_id == "alpha"
    assert focus_state.steering_target_kind == :child_session
    assert event.steering_target_pane_id == "child-session:alpha"
  end

  test "identifies the currently focused child pane as the concrete steering target" do
    pane_model = %{
      panes: %{
        "child-session:bravo" => %{
          id: "child-session:bravo",
          kind: :child_session,
          child_id: "bravo",
          parent_call_id: "parent-focus-target",
          transport: :stdio,
          external_ids: %{"native_session_id" => "native-bravo"}
        }
      },
      open: ["child-session:bravo"]
    }

    assert {:ok, focus_state, event} =
             FocusState.focus_pane(FocusState.new(), "child-session:bravo", pane_model,
               occurred_at_ms: 2_100
             )

    assert focus_state.focused_pane == "child-session:bravo"
    assert focus_state.steering_target == :child
    assert focus_state.steering_target_pane_id == "child-session:bravo"
    assert focus_state.steering_target_session_id == "bravo"
    assert focus_state.steering_target_kind == :child_session

    assert event.steering_target == :child
    assert event.steering_target_pane_id == "child-session:bravo"
    assert event.steering_target_session_id == "bravo"
    assert event.steering_target_kind == :child_session
  end

  test "focused_child_session returns the currently focused concrete child session" do
    pane_model = %{
      panes: %{
        "child-session:charlie" => %{
          id: "child-session:charlie",
          kind: :child_session,
          child_id: "charlie",
          parent_call_id: "parent-focus-resolver",
          transport: :streamable_http,
          external_ids: %{"native_session_id" => "native-charlie"}
        },
        parent: %{id: :parent, kind: :parent_session}
      },
      open: [:parent, "child-session:charlie"]
    }

    assert {:ok, focus_state, _event} =
             FocusState.focus_pane(FocusState.new(), "child-session:charlie", pane_model)

    assert {:ok,
            %{
              pane_id: "child-session:charlie",
              session_id: "charlie",
              child_id: "charlie",
              kind: :child_session,
              pane: %{parent_call_id: "parent-focus-resolver"}
            }} = FocusState.focused_child_session(focus_state, pane_model)
  end

  test "focused_child_session resolves string-key child pane metadata from replayed pane models" do
    child_pane_id = "child-pane:delta"

    pane_model = %{
      "panes" => %{
        "replayed-child-pane" => %{
          "id" => child_pane_id,
          "kind" => :child_session,
          "session_id" => "delta-session",
          "parent_call_id" => "parent-replay-focus",
          "external_ids" => %{"native_session_id" => "native-delta"}
        }
      },
      open: [child_pane_id]
    }

    assert {:ok, focus_state, _event} =
             FocusState.focus_pane(FocusState.new(), child_pane_id, pane_model)

    assert {:ok,
            %{
              pane_id: ^child_pane_id,
              session_id: "delta-session",
              child_id: "delta-session",
              kind: :child_session,
              pane: %{
                "parent_call_id" => "parent-replay-focus",
                "external_ids" => %{"native_session_id" => "native-delta"}
              }
            }} = FocusState.focused_child_session(focus_state, pane_model)
  end

  test "focused_child_session rejects aggregate child focus without a concrete session" do
    pane_model = %{
      panes: %{
        children: %{id: :children, kind: :child_sessions}
      },
      open: [:children]
    }

    assert {:ok, focus_state, _event} =
             FocusState.focus_pane(FocusState.new(), :children, pane_model)

    assert {:error, :no_focused_child_session} =
             FocusState.focused_child_session(focus_state, pane_model)
  end

  test "does not emit an event when the requested pane is already focused" do
    pane_model = %{
      panes: %{
        parent: %{id: :parent, kind: :parent_session},
        children: %{id: :children, kind: :child_sessions}
      },
      open: [:parent, :children]
    }

    assert {:ok, focused_state, focus_event} =
             FocusState.focus_pane(FocusState.new(), :children, pane_model, occurred_at_ms: 1_800)

    assert {:ok, same_state, nil} =
             FocusState.focus_pane(focused_state, "children", pane_model, occurred_at_ms: 1_900)

    assert same_state == focused_state
    assert same_state.history == [focus_event]
    assert same_state.focused_at_ms == 1_800
  end

  test "does not update focus when the requested pane id is unknown" do
    focus_state = FocusState.new()
    pane_model = %{panes: %{parent: %{id: :parent}}, open: [:parent]}

    assert {:error, {:unknown_pane, "missing-pane"}, ^focus_state} =
             FocusState.focus_pane(focus_state, "missing-pane", pane_model)
  end

  test "rejects a missing pane id without changing the previously focused pane" do
    pane_model = %{
      panes: %{
        parent: %{id: :parent, kind: :parent_session},
        children: %{id: :children, kind: :child_sessions}
      },
      open: [:parent, :children]
    }

    assert {:ok, focused_state, focus_event} =
             FocusState.focus_pane(FocusState.new(), :children, pane_model, occurred_at_ms: 2_300)

    assert {:error, {:unknown_pane, :missing}, rejected_state} =
             FocusState.focus_pane(focused_state, :missing, pane_model, occurred_at_ms: 2_400)

    assert rejected_state == focused_state
    assert rejected_state.focused_pane == :children
    assert rejected_state.previous_focused_pane == :task_prompt
    assert rejected_state.steering_target == :child
    assert rejected_state.focused_at_ms == 2_300
    assert rejected_state.history == [focus_event]
  end

  test "rejects a closed pane id without changing the previously focused pane" do
    pane_model = %{
      panes: %{
        parent: %{id: :parent, kind: :parent_session},
        children: %{id: :children, kind: :child_sessions},
        queue: %{id: :queue, kind: :queued_notifications}
      },
      open: [:parent, :children]
    }

    assert {:ok, focused_state, focus_event} =
             FocusState.focus_pane(FocusState.new(), :children, pane_model, occurred_at_ms: 2_500)

    assert {:error, {:unknown_pane, :queue}, rejected_state} =
             FocusState.focus_pane(focused_state, :queue, pane_model, occurred_at_ms: 2_600)

    assert rejected_state == focused_state
    assert rejected_state.focused_pane == :children
    assert rejected_state.previous_focused_pane == :task_prompt
    assert rejected_state.steering_target == :child
    assert rejected_state.focused_at_ms == 2_500
    assert rejected_state.history == [focus_event]
  end
end
