defmodule Ourocode.Dashboard.ChildSessionPaneStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneState

  test "new builds the canonical empty pane state" do
    assert ChildSessionPaneState.new() == %{
             working: [],
             completed: [],
             focused: nil,
             open: [],
             child_pane_registry: %{}
           }
  end

  test "registry returns the stored registry or an empty fallback" do
    assert ChildSessionPaneState.registry(%{child_pane_registry: %{"child-1" => "pane-1"}}) ==
             %{"child-1" => "pane-1"}

    assert ChildSessionPaneState.registry(%{}) == %{}
    assert ChildSessionPaneState.registry(%{child_pane_registry: nil}) == %{}
  end
end
