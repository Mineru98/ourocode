defmodule Ourocode.Terminal.EventLoopFocusTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.Runtime.FocusState
  alias Ourocode.Terminal.EventLoopFocus
  alias Ourocode.Terminal.FocusNavigation

  test "handle_keyboard ignores non-focus keys while advancing the loop iteration" do
    state = state()

    assert {:ok, updated} = EventLoopFocus.handle_keyboard(%{key: :unknown}, state)
    assert updated.iterations == 1
    assert updated.focus_state == state.focus_state
  end

  test "handle_keyboard records focus events for configured pane targets" do
    parent = self()
    journal_path = journal_path("keyboard-focus")

    state =
      state(%{
        journal_path: journal_path,
        on_focus_event: fn event, _startup_result -> send(parent, {:focus_event, event}) end
      })

    assert {:ok, updated} =
             EventLoopFocus.handle_keyboard(%{input_kind: :keyboard, key: :tab}, state)

    assert updated.iterations == 1
    assert updated.focus_state.focused_pane == :children

    assert [
             %{
               type: :focus_state_updated,
               source: :terminal_keyboard,
               input_kind: :keyboard,
               key: :tab,
               previous_focused_pane: :task_prompt,
               focused_pane: :children,
               steering_target: :child,
               payload: %{key: :tab}
             }
           ] = updated.focus_events

    assert_receive {:focus_event, %{source: :terminal_keyboard}}

    assert {:ok, [journaled]} = Journal.read_ordered(journal_path)
    assert journaled.type == :focus_state_updated
    assert journaled.source == :terminal_keyboard
    assert journaled.focused_pane == "children"
  end

  test "handle_keyboard for the current pane advances without journaling a focus event" do
    state =
      state(%{
        focus_state: %{
          focused_pane: :children,
          steering_target: :child,
          route: :focused_pane,
          history: []
        }
      })

    assert {:ok, updated} =
             EventLoopFocus.handle_keyboard(
               %{input_kind: :keyboard, key: :tab, target_pane_id: :children},
               state
             )

    assert updated.iterations == 1
    assert updated.focus_state.focused_pane == :children
    assert updated.focus_events == []
  end

  test "maybe_switch_from_command records pane command focus events" do
    journal_path = journal_path("command-focus")
    state = state(%{journal_path: journal_path})
    command_event = %{command: "/pane", args: ["children"], raw_input: "/pane children"}

    assert {:ok, updated} = EventLoopFocus.maybe_switch_from_command(command_event, state)

    assert updated.focus_state.focused_pane == :children

    assert [
             %{
               type: :focus_state_updated,
               source: :terminal_command,
               input_kind: :slash_command,
               command: "/pane",
               args: ["children"],
               previous_focused_pane: :task_prompt,
               focused_pane: :children,
               steering_target: :child,
               payload: %{command: "/pane"}
             }
           ] = updated.focus_events

    assert {:ok, [journaled]} = Journal.read_ordered(journal_path)
    assert journaled.type == :focus_state_updated
    assert journaled.source == :terminal_command
    assert journaled.focused_pane == "children"
  end

  test "maybe_switch_from_command for the current pane leaves focus events unchanged" do
    state =
      state(%{
        focus_state: %{
          focused_pane: :children,
          steering_target: :child,
          route: :focused_pane,
          history: []
        }
      })

    command_event = %{command: "/pane", args: ["children"], raw_input: "/pane children"}

    assert {:ok, updated} = EventLoopFocus.maybe_switch_from_command(command_event, state)

    assert updated.focus_state.focused_pane == :children
    assert updated.focus_events == []
  end

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        startup_result: %{},
        journal_path: nil,
        iterations: 0,
        focus_state: FocusState.new(),
        pane_model: FocusNavigation.default_pane_model(),
        keyboard_focus_bindings: FocusNavigation.keyboard_focus_bindings(%{}),
        focus_events: [],
        recoverable_errors: [],
        on_focus_event: fn _event, _startup_result -> :ok end
      },
      overrides
    )
  end

  defp journal_path(name) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")

    File.rm(path)
    path
  end
end
