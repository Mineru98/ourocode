defmodule Ourocode.Terminal.EventLoopExitTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.EventLoopExit

  test "shutdown_signal? matches exact normalized default and configured signals" do
    assert EventLoopExit.shutdown_signal?("/exit")
    assert EventLoopExit.shutdown_signal?("  QUIT  ")
    assert EventLoopExit.shutdown_signal?(":q")
    assert EventLoopExit.shutdown_signal?("done", exit_signals: ["done"])
    assert EventLoopExit.shutdown_signal?("STOP", exit_signals: MapSet.new(["stop"]))

    refute EventLoopExit.shutdown_signal?("/exit now")
    refute EventLoopExit.shutdown_signal?("please exit after summarizing the pane")
    refute EventLoopExit.shutdown_signal?("quit after the child stream is replayed")
    refute EventLoopExit.shutdown_signal?("/quit-now")
    refute EventLoopExit.shutdown_signal?("done after replay", exit_signals: ["done"])
    refute EventLoopExit.shutdown_signal?("/stop", exit_signals: ["stop"])
    refute EventLoopExit.shutdown_signal?(123)
  end

  test "result reverses accumulated event buffers and preserves terminal state fields" do
    state = %{
      iterations: 2,
      submitted_tasks: [:second_task, :first_task],
      input_events: [:second_input, :first_input],
      accepted_input_buffer: [:second_buffered, :first_buffered],
      runtime_events: [:second_runtime, :first_runtime],
      plugin_status_updates: [:second_plugin, :first_plugin],
      command_events: [:second_command, :first_command],
      command_palette_events: [:second_palette, :first_palette],
      command_errors: [:second_error, :first_error],
      focus_events: [:second_focus, :first_focus],
      focus_state: %{focused_pane: "pane-1"},
      pane_model: %{panes: []},
      recoverable_errors: [:second_recoverable, :first_recoverable],
      prompt_state: :awaiting_prompt,
      prompt_state_events: [:second_prompt, :first_prompt]
    }

    assert EventLoopExit.result(:exit_signal_received, "/exit", state, true) == %{
             status: :exit_signal_received,
             iterations: 2,
             submitted_tasks: [:first_task, :second_task],
             input_events: [:first_input, :second_input],
             accepted_input_buffer: [:first_buffered, :second_buffered],
             runtime_events: [:first_runtime, :second_runtime],
             plugin_status_updates: [:first_plugin, :second_plugin],
             command_events: [:first_command, :second_command],
             command_palette_events: [:first_palette, :second_palette],
             command_errors: [:first_error, :second_error],
             focus_events: [:first_focus, :second_focus],
             focus_state: %{focused_pane: "pane-1"},
             pane_model: %{panes: []},
             recoverable_errors: [:first_recoverable, :second_recoverable],
             prompt_state: :awaiting_prompt,
             prompt_state_events: [:first_prompt, :second_prompt],
             exit_signal: "/exit",
             resources_released?: true
           }
  end
end
