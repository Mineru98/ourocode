defmodule Ourocode.Terminal.FocusNavigationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.FocusNavigation

  test "normalizes default and configured keyboard focus bindings" do
    bindings =
      FocusNavigation.keyboard_focus_bindings(%{
        keyboard_focus_bindings: %{"Ctrl-X" => :custom, shift_tab: :alternate_parent}
      })

    assert bindings["tab"] == :children
    assert bindings["ctrl_x"] == :custom
    assert bindings["shift_tab"] == :alternate_parent
  end

  test "resolves explicit keyboard target before key bindings" do
    bindings = FocusNavigation.keyboard_focus_bindings(%{})

    assert FocusNavigation.resolve_keyboard_focus_target(
             %{input_kind: :keyboard, key: :tab, target_pane_id: :status},
             bindings
           ) == {:ok, :status}

    assert FocusNavigation.resolve_keyboard_focus_target(%{key: "shift-tab"}, bindings) ==
             {:ok, :parent}
  end

  test "decorates focus events with keyboard payload context" do
    event =
      FocusNavigation.keyboard_focus_event(
        %{
          type: :focus_state_updated,
          focused_pane: :children,
          previous_focused_pane: :parent,
          steering_target: :child,
          steering_target_pane_id: :children
        },
        %{input_kind: :keyboard, key: :tab}
      )

    assert event.source == :terminal_keyboard
    assert event.input_kind == :keyboard
    assert event.payload.focused_pane == :children
    assert event.payload.previous_focused_pane == :parent
    assert event.payload.key == :tab
  end

  test "detects command focus targets for pane commands only" do
    assert FocusNavigation.command_focus_target(%{command: "/pane", args: ["children"]}) ==
             {:ok, "children"}

    assert FocusNavigation.command_focus_target(%{command: "/focus-pane", args: [:parent]}) ==
             {:ok, :parent}

    assert FocusNavigation.command_focus_target(%{command: "/capabilities", args: []}) ==
             :ignore
  end
end
