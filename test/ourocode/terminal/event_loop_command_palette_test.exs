defmodule Ourocode.Terminal.EventLoopCommandPaletteTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry
  alias Ourocode.Terminal.EventLoopCommandPalette

  test "open_event builds a palette opened event from a registry" do
    registry = registry()

    event = EventLoopCommandPalette.open_event("/", registry)

    assert event.type == :command_palette_opened
    assert event.input_kind == :slash_palette_trigger
    assert event.registry.status == registry.status
    assert event.registry.loaded_count == registry.loaded_count
    assert Enum.map(event.registry.entries, & &1.slash) == Enum.map(registry.ordered, & &1.slash)
  end

  test "select_event returns selected entry and selection event" do
    registry = registry()
    opened = EventLoopCommandPalette.open_event("/", registry)

    assert {:ok, {entry, event}} =
             EventLoopCommandPalette.select_event("1", registry, opened, %{})

    assert entry.slash == "/help"
    assert event.type == :command_palette_selected
    assert event.selected_slash == "/help"
  end

  test "select_event returns recoverable error event for invalid selections" do
    registry = registry()
    opened = EventLoopCommandPalette.open_event("/", registry)

    assert {:error, event} = EventLoopCommandPalette.select_event("99", registry, opened, %{})

    assert event.type == :terminal_recoverable_error
    assert event.error_type == :command_palette_selection_failed
    assert event.reason != nil
  end

  test "render_model and render_text expose command palette area shape" do
    registry = registry()
    event_registry = EventLoopCommandPalette.open_event("/", registry).registry

    assert EventLoopCommandPalette.render_model(event_registry) == %{
             id: :command_palette,
             region: :command_palette,
             title: "Command Palette",
             status: registry.status,
             loaded_count: registry.loaded_count,
             sources: registry.sources,
             entries: event_registry.entries
           }

    assert EventLoopCommandPalette.render_text(event_registry) =~ "/help"
  end

  defp registry do
    {:ok, registry} = Registry.load_builtin()
    registry
  end
end
