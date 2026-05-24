defmodule Ourocode.Terminal.CommandInputEventsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry
  alias Ourocode.Terminal.CommandInputEvents

  test "builds submitted and failed slash command events" do
    event = CommandInputEvents.command_event(" /status verbose ")

    assert event.type == :slash_command_submitted
    assert event.command == "/status"
    assert event.args == ["verbose"]
    assert event.payload.raw_input == " /status verbose "

    error =
      CommandInputEvents.command_error_event(event, {:unknown_command, "/stats", ["/status"]})

    assert error.type == :slash_command_failed
    assert error.command == "/status"
    assert error.reason == {:unknown_command, "/stats", ["/status"]}
    assert error.payload.reason == {:unknown_command, "/stats", ["/status"]}
  end

  test "builds palette opened and selection events" do
    {:ok, registry} = Registry.load_builtin()
    selected = registry |> Registry.entries() |> List.first()
    opened = CommandInputEvents.palette_open_event("/", registry)
    selected_event = CommandInputEvents.palette_selection_event("1", selected, opened, registry)

    assert opened.type == :command_palette_opened
    assert opened.registry.loaded_count > 0
    assert opened.payload.registry.entries != []

    assert selected_event.type == :command_palette_selected
    assert selected_event.selected_slash == selected.slash
    assert selected_event.selection_index == 1
    assert selected_event.payload.selected_registry_item == selected
  end
end
