defmodule Ourocode.Terminal.PromptActivityIndicator do
  @moduledoc """
  Compact prompt activity frames for accepted input.

  Mirrors grok-cli's OpenTUI prompt loading boxes: a short three-cell indicator
  moves quickly while the runtime opens the first visible update.
  The indicator is lifecycle feedback only, not model reasoning.
  """

  @frames ["■⬝⬝", "■■⬝", "⬝■■", "⬝⬝■"]

  @spec frame(non_neg_integer()) :: String.t()
  def frame(tick), do: Enum.at(@frames, rem(tick, length(@frames)))

  @spec frames() :: [String.t()]
  def frames, do: @frames
end
