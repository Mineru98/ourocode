defmodule Ourocode.Terminal.EventLoopCommandDispatchTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.CommandInput
  alias Ourocode.Terminal.EventLoopCommandDispatch
  alias Ourocode.Terminal.EventLoopState

  test "submit persists a command event and records successful dispatch" do
    command_event = CommandInput.command_event("/status")
    state = state(on_command: fn _event, _args, _startup -> :ok end)

    assert {:ok, state} = EventLoopCommandDispatch.submit(command_event, state)

    assert state.iterations == 1
    assert [%{command: "/status"}] = state.command_events
    assert state.command_errors == []
  end

  test "submit records command handler failures as recoverable command errors" do
    command_event = CommandInput.command_event("/missing")
    output = string_io()

    state =
      state(
        output: output,
        on_command: fn _event, _args, _startup -> {:error, {:unknown_command, "/missing", []}} end
      )

    assert {:ok, state} = EventLoopCommandDispatch.submit(command_event, state)

    assert state.iterations == 1
    assert [%{command: "/missing"}] = state.command_events
    assert [%{type: :slash_command_failed, command: "/missing"}] = state.command_errors

    assert {_input, output_text} = StringIO.contents(output)
    assert output_text =~ "command /missing failed: unknown command /missing"
  end

  test "dispatch normalizes raised command handler exceptions" do
    command_event = CommandInput.command_event("/explode")

    state =
      state(
        on_command: fn _event, _args, _startup ->
          raise ArgumentError, "bad command"
        end
      )

    assert {:error, {:command_handler_exception, ArgumentError, "bad command"}} =
             EventLoopCommandDispatch.dispatch(command_event, state)
  end

  defp state(options) do
    options =
      Keyword.merge(
        [
          output: string_io(),
          on_command_error: fn _error, _event, _startup -> :ok end
        ],
        options
      )

    EventLoopState.build(%{status: :healthy}, options, "ourocode> ")
  end

  defp string_io do
    {:ok, output} = StringIO.open("")
    output
  end
end
