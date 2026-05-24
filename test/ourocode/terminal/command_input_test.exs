defmodule Ourocode.Terminal.CommandInputTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry
  alias Ourocode.Terminal.CommandInput

  test "classifies slash command and palette input lines" do
    assert CommandInput.slash_command?(" /status")
    assert CommandInput.palette_trigger?(" / ")
    assert CommandInput.palette_selection?("2", %{registry: %{}})

    refute CommandInput.slash_command?("run a task")
    refute CommandInput.palette_trigger?("/status")
    refute CommandInput.palette_selection?("two", %{registry: %{}})
    refute CommandInput.palette_selection?("2", nil)
  end

  test "builds slash command submitted and failed events" do
    event = CommandInput.command_event(" /status verbose ")

    assert event.type == :slash_command_submitted
    assert event.command == "/status"
    assert event.args == ["verbose"]
    assert event.payload.raw_input == " /status verbose "

    error = CommandInput.command_error_event(event, {:unknown_command, "/stats", ["/status"]})

    assert error.type == :slash_command_failed
    assert error.command == "/status"
    assert error.reason == {:unknown_command, "/stats", ["/status"]}
    assert error.payload.reason == {:unknown_command, "/stats", ["/status"]}
  end

  test "builds command palette open and selection events from registry data" do
    {:ok, registry} = Registry.load_builtin()
    selected = registry |> Registry.entries() |> List.first()
    opened = CommandInput.palette_open_event("/", registry)
    selected_event = CommandInput.palette_selection_event("1", selected, opened, registry)

    assert opened.type == :command_palette_opened
    assert opened.registry.loaded_count > 0
    assert opened.payload.registry.entries != []

    assert selected_event.type == :command_palette_selected
    assert selected_event.selected_slash == selected.slash
    assert selected_event.selection_index == 1
    assert selected_event.payload.selected_registry_item == selected
  end

  test "formats unknown command errors with suggestions" do
    assert CommandInput.format_error({:unknown_command, "/capabilites", ["/capabilities"]}) ==
             "unknown command /capabilites. did you mean /capabilities?"

    assert CommandInput.format_error({:unknown_command, "/bogus", []}) ==
             "unknown command /bogus"
  end

  test "suggests nearby registered commands from slash names and aliases" do
    {:ok, registry} = Registry.load_builtin()

    assert "/capabilities" in CommandInput.command_suggestions(registry, "/capabilites")
    assert "/help" in CommandInput.command_suggestions(registry, "/h")

    assert {:unknown_command, "/capabilites", suggestions} =
             CommandInput.unknown_command_reason("/capabilites", registry)

    assert "/capabilities" in suggestions
    assert length(suggestions) <= 3
  end
end
