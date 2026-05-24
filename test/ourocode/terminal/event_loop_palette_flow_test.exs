defmodule Ourocode.Terminal.EventLoopPaletteFlowTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry
  alias Ourocode.Journal
  alias Ourocode.Terminal.EventLoopCommandPalette
  alias Ourocode.Terminal.EventLoopPaletteFlow

  test "open persists callback state and activates the palette" do
    {:ok, output} = StringIO.open("")
    parent = self()
    registry = registry()
    journal_path = journal_path("palette-open")

    state =
      base_state(%{
        journal_path: journal_path,
        output: output,
        on_command_palette: fn event, startup_result ->
          send(parent, {:opened, event, startup_result})
        end
      })

    assert {:ok, next_state} = EventLoopPaletteFlow.open("/", state, registry)

    assert next_state.iterations == 1
    assert %{registry: ^registry, opened_event: opened_event} = next_state.active_command_palette
    assert [^opened_event] = next_state.command_palette_events
    assert opened_event.type == :command_palette_opened
    assert opened_event.raw_input == "/"
    assert opened_event.submitted? == false
    assert opened_event.prompt_mutated? == false
    assert_receive {:opened, ^opened_event, %{runtime: :fake}}

    assert {:ok, [journaled]} = Journal.read_ordered(journal_path)
    assert journaled.type == :command_palette_opened
    assert journaled.raw_input == "/"
    assert journaled["submitted?"] == false
    assert journaled["prompt_mutated?"] == false
    assert journaled.payload["action"] == "command_palette_open"
    assert journaled.payload["raw_input"] == "/"
    assert journaled.payload["submitted?"] == false
    assert journaled.payload["prompt_mutated?"] == false

    {_input, output_text} = StringIO.contents(output)
    assert output_text =~ "Command Palette"
  end

  test "select persists selection state and clears the active palette" do
    {:ok, output} = StringIO.open("")
    parent = self()
    registry = registry()
    opened_event = EventLoopCommandPalette.open_event("/", registry)
    journal_path = journal_path("palette-selection")
    assert :ok = Journal.append(journal_path, opened_event)

    state =
      base_state(%{
        journal_path: journal_path,
        output: output,
        active_command_palette: %{registry: registry, opened_event: opened_event},
        command_palette_events: [opened_event],
        on_command_palette_selection: fn event, startup_result ->
          send(parent, {:selected, event, startup_result})
        end
      })

    assert {:ok, next_state} = EventLoopPaletteFlow.select("1", state)

    assert next_state.iterations == 1
    assert next_state.active_command_palette == nil

    assert [%{type: :command_palette_selected} = selection_event, ^opened_event] =
             next_state.command_palette_events

    assert selection_event.selected_slash == "/help"
    assert_receive {:selected, ^selection_event, %{runtime: :fake}}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, & &1.type) == [
             :command_palette_opened,
             :command_palette_selected
           ]

    selection_journal_event = List.last(journaled)
    assert selection_journal_event.selected_slash == "/help"
    assert selection_journal_event.selected_registry_item["slash"] == "/help"
    assert selection_journal_event.payload["selected_registry_item"]["slash"] == "/help"

    {_input, output_text} = StringIO.contents(output)
    assert output_text =~ "selected /help"
  end

  test "invalid selection records a recoverable error and keeps palette active" do
    {:ok, output} = StringIO.open("")
    registry = registry()
    opened_event = EventLoopCommandPalette.open_event("/", registry)

    state =
      base_state(%{
        output: output,
        active_command_palette: %{registry: registry, opened_event: opened_event}
      })

    assert {:ok, next_state} = EventLoopPaletteFlow.select("999", state)

    assert next_state.iterations == 1
    assert next_state.active_command_palette == state.active_command_palette

    assert [%{type: :terminal_recoverable_error, error_type: :command_palette_selection_failed}] =
             next_state.recoverable_errors

    {_input, output_text} = StringIO.contents(output)
    assert output_text =~ "palette selection failed:"
  end

  defp base_state(attrs) do
    Map.merge(
      %{
        startup_result: %{runtime: :fake},
        output: :stdio,
        journal_path: nil,
        iterations: 0,
        active_command_palette: nil,
        command_palette_events: [],
        recoverable_errors: [],
        on_command_palette: fn _event, _startup_result -> :ok end,
        on_command_palette_selection: fn _event, _startup_result -> :ok end
      },
      attrs
    )
  end

  defp registry do
    {:ok, registry} = Registry.load_builtin()
    registry
  end

  defp journal_path(name) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")

    File.rm(path)
    path
  end
end
