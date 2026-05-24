defmodule Ourocode.Runtime.FocusPaneModelTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.FocusPaneModel

  test "resolves atom and string pane ids from open panes" do
    pane_model = %{
      open: [:children, "parent", :child_slot],
      panes: %{
        child_slot: %{id: "child-session:alpha"}
      }
    }

    assert FocusPaneModel.resolve_pane_id("children", pane_model) == {:ok, :children}
    assert FocusPaneModel.resolve_pane_id(:parent, pane_model) == {:ok, "parent"}

    assert FocusPaneModel.resolve_pane_id("child-session:alpha", pane_model) ==
             {:ok, "child-session:alpha"}

    assert FocusPaneModel.resolve_pane_id("missing", pane_model) == :error
  end

  test "classifies steering targets from known panes and prefixed pane ids" do
    assert FocusPaneModel.steering_target(:task_prompt) == :parent
    assert FocusPaneModel.steering_target(:children) == :child
    assert FocusPaneModel.steering_target("child-session:alpha") == :child
    assert FocusPaneModel.steering_target("parent-mcp:call-1") == :parent
    assert FocusPaneModel.steering_target("custom-pane") == :pane
  end

  test "builds child steering metadata from pane fields, external ids, and pane id fallback" do
    pane_model = %{
      panes: %{
        "child-pane:alpha" => %{
          "id" => "child-pane:alpha",
          "kind" => :child_session,
          "external_ids" => %{"thread_id" => "thread-1"}
        },
        "child-pane:bravo" => %{
          id: "child-pane:bravo",
          session_id: "session-bravo"
        },
        "child-pane:charlie" => %{
          id: "child-pane:charlie"
        }
      }
    }

    assert FocusPaneModel.steering_target_metadata("child-pane:alpha", pane_model, :child) == %{
             pane_id: "child-pane:alpha",
             session_id: "thread-1",
             kind: :child_session
           }

    assert FocusPaneModel.steering_target_metadata("child-pane:bravo", pane_model, :child) == %{
             pane_id: "child-pane:bravo",
             session_id: "session-bravo",
             kind: :child
           }

    assert FocusPaneModel.steering_target_metadata("child-pane:charlie", pane_model, :child) == %{
             pane_id: "child-pane:charlie",
             session_id: "charlie",
             kind: :child
           }
  end
end
