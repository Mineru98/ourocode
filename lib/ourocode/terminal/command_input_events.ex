defmodule Ourocode.Terminal.CommandInputEvents do
  @moduledoc """
  Event builders for slash-command and command-palette terminal input.
  """

  alias Ourocode.Command.Registry, as: CommandRegistry
  alias Ourocode.Terminal.CommandPaletteArea

  @doc """
  Builds a submitted slash-command input event.
  """
  @spec command_event(String.t()) :: map()
  def command_event(line) when is_binary(line) do
    {command, args} = parse_command(line)

    %{
      type: :slash_command_submitted,
      event_type: :slash_command_submitted,
      source: :terminal_prompt,
      input_kind: :slash_command,
      command: command,
      args: args,
      raw_input: line,
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        command: command,
        args: args,
        raw_input: line
      }
    }
  end

  @doc """
  Builds a slash-command failure event from a submitted command event.
  """
  @spec command_error_event(map(), term()) :: map()
  def command_error_event(command_event, reason) when is_map(command_event) do
    %{
      type: :slash_command_failed,
      event_type: :slash_command_failed,
      source: :terminal_prompt,
      input_kind: :slash_command,
      command: command_event.command,
      args: command_event.args,
      raw_input: command_event.raw_input,
      reason: reason,
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        command: command_event.command,
        args: command_event.args,
        raw_input: command_event.raw_input,
        reason: reason
      }
    }
  end

  @doc """
  Builds a command-palette opened event from the current registry.
  """
  @spec palette_open_event(String.t(), map()) :: map()
  def palette_open_event(line, registry) when is_binary(line) and is_map(registry) do
    entries = CommandPaletteArea.event_entries(registry)

    registry_summary = %{
      status: Map.get(registry, :status),
      loaded_count: Map.get(registry, :loaded_count, 0),
      sources: Map.get(registry, :sources, []),
      entries: entries
    }

    %{
      type: :command_palette_opened,
      event_type: :command_palette_opened,
      source: :terminal_prompt,
      input_kind: :slash_palette_trigger,
      action: :command_palette_open,
      raw_input: line,
      prompt_mutated?: false,
      submitted?: false,
      occurred_at_ms: System.system_time(:millisecond),
      registry: registry_summary,
      payload: %{
        action: :command_palette_open,
        raw_input: line,
        prompt_mutated?: false,
        submitted?: false,
        registry: registry_summary
      }
    }
  end

  @doc """
  Builds a command-palette selection event for one registry entry.
  """
  @spec palette_selection_event(String.t(), map(), map(), map()) :: map()
  def palette_selection_event(line, selected_entry, opened_event, registry)
      when is_binary(line) and is_map(selected_entry) and is_map(opened_event) and
             is_map(registry) do
    selection_index =
      registry
      |> CommandRegistry.entries()
      |> Enum.find_index(&(&1.slash == selected_entry.slash))
      |> case do
        nil -> nil
        index -> index + 1
      end

    %{
      type: :command_palette_selected,
      event_type: :command_palette_selected,
      source: :terminal_prompt,
      input_kind: :slash_palette_selection,
      action: :command_palette_select,
      raw_input: line,
      prompt_mutated?: false,
      submitted?: false,
      selection_index: selection_index,
      selected_slash: selected_entry.slash,
      selected_registry_item: selected_entry,
      opened_event_seq: Map.get(opened_event, :event_seq),
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        action: :command_palette_select,
        raw_input: line,
        prompt_mutated?: false,
        submitted?: false,
        selection_index: selection_index,
        selected_slash: selected_entry.slash,
        selected_registry_item: selected_entry,
        opened_event_seq: Map.get(opened_event, :event_seq)
      }
    }
  end

  defp parse_command(line) do
    [command | args] =
      line
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    {command, args}
  end
end
