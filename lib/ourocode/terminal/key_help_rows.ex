defmodule Ourocode.Terminal.KeyHelpRows do
  @moduledoc """
  Selects key help rows for the current TUI interaction state.
  """

  @type row :: {String.t(), String.t()}

  @spec rows(atom(), map()) :: [row()]
  def rows(mode, opts) when is_map(opts) do
    case {mode, Map.get(opts, :wonder_focus, false), Map.get(opts, :interview_paused, false)} do
      {_mode, true, _paused} ->
        [
          {"Up/Dn j/k", "move option"},
          {"Left/Right h/l", "move question"},
          {"Space", "toggle multi-select"},
          {"Enter", "submit or review"},
          {"Esc", "pause to main session"}
        ]

      {_mode, _focus, true} ->
        [
          {"/answer <text>", "submit to interview"},
          {"type normally", "discuss with main session"},
          {"Ctrl-G", "hide this help"}
        ]

      {:palette, _focus, _paused} ->
        [{"Up/Dn", "move"}, {"Enter", "run"}, {"Esc", "close"}, {"Ctrl-G", "hide help"}]

      _other ->
        [
          {"/", "commands"},
          {"@", "file mentions"},
          {"Up/Ctrl-P", "history"},
          {"Ctrl-A/E", "line start/end"},
          {"Ctrl-G", "hide help"}
        ]
    end
  end
end
