defmodule Ourocode.Terminal.CommandInput do
  @moduledoc false

  alias Ourocode.Terminal.CommandInputError
  alias Ourocode.Terminal.CommandInputEvents
  alias Ourocode.Terminal.CommandSuggestions

  @spec trim_terminal_line_ending(String.t()) :: String.t()
  def trim_terminal_line_ending(line) when is_binary(line) do
    line
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end

  @spec slash_command?(String.t()) :: boolean()
  def slash_command?(line) do
    line
    |> String.trim_leading()
    |> String.starts_with?("/")
  end

  @spec palette_trigger?(String.t()) :: boolean()
  def palette_trigger?(line), do: String.trim(line) == "/"

  @spec palette_selection?(String.t(), map() | nil) :: boolean()
  def palette_selection?(_line, nil), do: false

  def palette_selection?(line, active_palette) when is_map(active_palette) and is_binary(line) do
    case Integer.parse(String.trim(line)) do
      {index, ""} when index > 0 -> true
      _other -> false
    end
  end

  @spec command_event(String.t()) :: map()
  def command_event(line) do
    CommandInputEvents.command_event(line)
  end

  @spec command_error_event(map(), term()) :: map()
  def command_error_event(command_event, reason) do
    CommandInputEvents.command_error_event(command_event, reason)
  end

  @spec palette_open_event(String.t(), map()) :: map()
  def palette_open_event(line, registry) do
    CommandInputEvents.palette_open_event(line, registry)
  end

  @spec palette_selection_event(String.t(), map(), map(), map()) :: map()
  def palette_selection_event(line, selected_entry, opened_event, registry) do
    CommandInputEvents.palette_selection_event(line, selected_entry, opened_event, registry)
  end

  @spec format_error(term()) :: String.t()
  def format_error(reason) do
    CommandInputError.format(reason)
  end

  @spec unknown_command_reason(String.t(), map()) :: {:unknown_command, String.t(), [String.t()]}
  def unknown_command_reason(command, registry),
    do: CommandSuggestions.unknown_reason(command, registry)

  @spec command_suggestions(map(), String.t()) :: [String.t()]
  def command_suggestions(registry, command),
    do: CommandSuggestions.suggestions(registry, command)
end
