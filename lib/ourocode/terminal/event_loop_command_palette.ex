defmodule Ourocode.Terminal.EventLoopCommandPalette do
  @moduledoc """
  Command palette helpers used by the terminal event loop.
  """

  alias Ourocode.Terminal.CommandInput
  alias Ourocode.Terminal.CommandPaletteArea
  alias Ourocode.Terminal.RuntimeEventFlow

  @spec open_event(String.t(), map()) :: map()
  def open_event(line, registry) when is_binary(line) and is_map(registry) do
    CommandInput.palette_open_event(line, registry)
  end

  @spec select_event(String.t(), map(), map(), map()) ::
          {:ok, {map(), map()}} | {:error, map()}
  def select_event(line, registry, opened_event, _state) when is_binary(line) do
    case CommandPaletteArea.select(registry, line) do
      {:ok, selected_entry} ->
        selection_event =
          CommandInput.palette_selection_event(line, selected_entry, opened_event, registry)

        {:ok, {selected_entry, selection_event}}

      {:error, reason} ->
        {:error,
         RuntimeEventFlow.recoverable_error_event(
           :command_palette_selection_failed,
           reason,
           :terminal_prompt
         )}
    end
  end

  @spec render_text(map()) :: String.t()
  def render_text(registry) when is_map(registry) do
    registry
    |> render_model()
    |> CommandPaletteArea.render_text()
  end

  @spec render_model(map()) :: map()
  def render_model(%{
        status: status,
        loaded_count: loaded_count,
        sources: sources,
        entries: entries
      }) do
    %{
      id: :command_palette,
      region: :command_palette,
      title: "Command Palette",
      status: status,
      loaded_count: loaded_count,
      sources: sources,
      entries: entries
    }
  end
end
