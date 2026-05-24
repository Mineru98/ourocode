defmodule Ourocode.Terminal.SteeringPaneTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.SteeringPane

  test "appends pane-directed steering messages to the targeted child pane" do
    pane_model = %{
      panes: %{
        child: %{
          id: "child-session:alpha",
          kind: :child_session,
          pane_state: %{stream_entries: [%{token: "existing"}], last_event_seq: 3}
        },
        sibling: %{
          id: "child-session:bravo",
          kind: :child_session,
          pane_state: %{stream_entries: []}
        }
      }
    }

    input_event = %{
      event_seq: 4,
      task_request_id: "task-4",
      steering_target: :child,
      steering_target_pane_id: "child-session:alpha",
      steering_target_session_id: "alpha",
      steering_target_kind: :child_session,
      steering_text: "continue this run",
      steering_message: %{
        type: :pane_directed_steering_message,
        target_pane_id: "child-session:alpha",
        target_session_id: "alpha",
        target_kind: :child_session,
        content: "continue this run"
      },
      occurred_at_ms: 1_234
    }

    updated = SteeringPane.append_to_target_child_pane(pane_model, input_event)

    assert get_in(updated, [:panes, :sibling, :pane_state, :stream_entries]) == []
    assert get_in(updated, [:panes, :child, :pane_state, :last_event_seq]) == 4

    assert get_in(updated, [:panes, :child, :pane_state, :stream_entries]) == [
             %{token: "existing"},
             %{
               type: :pane_directed_steering_message,
               event_seq: 4,
               task_request_id: "task-4",
               content: "continue this run",
               target_pane_id: "child-session:alpha",
               target_session_id: "alpha",
               target_kind: :child_session,
               payload: %{
                 type: :pane_directed_steering_message,
                 target_pane_id: "child-session:alpha",
                 target_session_id: "alpha",
                 target_kind: :child_session,
                 content: "continue this run"
               },
               occurred_at_ms: 1_234
             }
           ]
  end

  test "ignores non-child steering and aggregate panes" do
    pane_model = %{
      panes: %{
        parent: %{id: :parent, kind: :parent, pane_state: %{stream_entries: []}},
        aggregate: %{
          id: "child-session:alpha",
          kind: :child_group,
          pane_state: %{stream_entries: []}
        }
      }
    }

    assert SteeringPane.append_to_target_child_pane(pane_model, %{
             steering_target: :parent,
             steering_target_pane_id: "child-session:alpha"
           }) == pane_model

    assert SteeringPane.append_to_target_child_pane(pane_model, %{
             steering_target: :child,
             steering_target_pane_id: "child-session:alpha"
           }) == pane_model
  end

  test "preserves existing stream order across repeated child steering messages" do
    pane_model = %{
      panes: %{
        child: %{
          id: "child-session:alpha",
          kind: :child_session,
          pane_state: %{
            stream_entries: [
              %{type: :child_stream_event, event_seq: 0, content: "existing child output"}
            ]
          }
        },
        sibling: %{
          id: "child-session:bravo",
          kind: :child_session,
          pane_state: %{stream_entries: []}
        }
      }
    }

    updated =
      pane_model
      |> SteeringPane.append_to_target_child_pane(input_event(1, "first child-directed message"))
      |> SteeringPane.append_to_target_child_pane(input_event(2, "second child-directed message"))

    target_entries = get_in(updated, [:panes, :child, :pane_state, :stream_entries])

    assert Enum.map(target_entries, & &1.event_seq) == [0, 1, 2]

    assert [
             %{type: :child_stream_event, content: "existing child output"},
             %{
               type: :pane_directed_steering_message,
               event_seq: 1,
               content: "first child-directed message",
               target_pane_id: "child-session:alpha",
               target_session_id: "alpha"
             },
             %{
               type: :pane_directed_steering_message,
               event_seq: 2,
               content: "second child-directed message",
               target_pane_id: "child-session:alpha",
               target_session_id: "alpha"
             }
           ] = target_entries

    assert get_in(updated, [:panes, :sibling, :pane_state, :stream_entries]) == []
    assert get_in(updated, [:panes, :child, :pane_state, :last_event_seq]) == 2
  end

  defp input_event(event_seq, content) do
    %{
      event_seq: event_seq,
      task_request_id: "task-#{event_seq}",
      steering_target: :child,
      steering_target_pane_id: "child-session:alpha",
      steering_target_session_id: "alpha",
      steering_target_kind: :child_session,
      steering_text: content,
      steering_message: %{
        type: :pane_directed_steering_message,
        target_pane_id: "child-session:alpha",
        target_session_id: "alpha",
        target_kind: :child_session,
        content: content
      },
      occurred_at_ms: event_seq
    }
  end
end
