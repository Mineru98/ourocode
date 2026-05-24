defmodule Ourocode.Terminal.HeaderStatusArea do
  @moduledoc """
  Terminal-native header/status area projection.

  The dashboard header remains the source projection for app/runtime state. This
  module owns terminal geometry and bounds so renderers can prove that the
  persistent UI has a stable header region.
  """

  alias Ourocode.Dashboard.HeaderStatusArea, as: DashboardHeaderStatusArea
  alias Ourocode.Terminal.LayoutSegment

  @width 88
  @height 5

  @type rectangle :: %{
          required(:x) => non_neg_integer(),
          required(:y) => non_neg_integer(),
          required(:width) => pos_integer(),
          required(:height) => pos_integer()
        }

  @type rendered_area :: %{
          required(:id) => :header_status,
          required(:kind) => :terminal_header_status_area,
          required(:title) => String.t(),
          required(:layout) => map(),
          required(:app) => String.t(),
          required(:status) => atom() | String.t(),
          required(:healthy?) => boolean(),
          required(:runtime_status) => atom() | String.t(),
          required(:session_id) => String.t(),
          required(:project_dir) => String.t(),
          required(:cwd) => String.t()
        }

  @doc """
  Builds a render-ready terminal header/status area with fixed geometry.
  """
  @spec render(map()) :: rendered_area()
  def render(startup_result) when is_map(startup_result) do
    startup_result
    |> DashboardHeaderStatusArea.render()
    |> Map.put(:layout, %{
      mode: :compact,
      region: :header_status,
      order: 0,
      rect: %{x: 0, y: 0, width: @width, height: @height}
    })
  end

  @doc """
  Renders the header/status area as terminal-safe text bounded by its rectangle.
  """
  @spec render_text(rendered_area() | map()) :: String.t()
  def render_text(%{id: :header_status, layout: %{rect: rect}} = area) do
    [
      "+-- #{area.title} #{LayoutSegment.format(area, "unknown")}",
      "| app=#{area.app} status=#{area.status} runtime=#{area.runtime_status} session=#{area.session_id}",
      "| project=#{area.project_dir}",
      "| cwd=#{area.cwd}",
      "+--"
    ]
    |> Enum.map(&clip_line(&1, rect.width))
    |> Enum.join("\n")
  end

  def render_text(startup_result) when is_map(startup_result) do
    startup_result
    |> render()
    |> render_text()
  end

  defp clip_line(line, width) when is_binary(line) and is_integer(width) do
    if String.length(line) <= width do
      line
    else
      String.slice(line, 0, width)
    end
  end
end
