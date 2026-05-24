defmodule Ourocode.Terminal.LayoutSegment do
  @moduledoc """
  Formats terminal area layout metadata for text renderers.
  """

  @spec format(map(), String.t()) :: String.t()
  def format(%{layout: %{rect: rect, region: region}}, _fallback_region) when is_map(rect) do
    "region=#{region} #{rect(rect)}"
  end

  def format(_area, fallback_region), do: "region=#{fallback_region}"

  @doc """
  Formats a terminal rectangle without adding a region prefix.
  """
  @spec rect(map()) :: String.t()
  def rect(%{x: x, y: y, width: width, height: height}) do
    "x=#{x} y=#{y} w=#{width} h=#{height}"
  end
end
