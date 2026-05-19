defmodule Ourocode.Terminal.HeaderStatusAreaTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.HeaderStatusArea

  test "renders the terminal header/status area with stable placement and bounds" do
    area =
      HeaderStatusArea.render(%{
        status: :healthy,
        healthy?: true,
        context: %{
          project_dir: "/project/ourocode",
          cwd: "/project/ourocode",
          runtime: %{session_id: "session-123", status: :ready}
        }
      })

    assert area.id == :header_status
    assert area.kind == :terminal_header_status_area

    assert area.layout == %{
             mode: :compact,
             region: :header_status,
             order: 0,
             rect: %{x: 0, y: 0, width: 88, height: 5}
           }

    text = HeaderStatusArea.render_text(area)
    lines = String.split(text, "\n")

    assert length(lines) == area.layout.rect.height
    assert Enum.all?(lines, &(String.length(&1) <= area.layout.rect.width))
    assert Enum.at(lines, 0) == "+-- ourocode terminal region=header_status x=0 y=0 w=88 h=5"
    assert Enum.at(lines, 1) == "| app=ourocode status=healthy runtime=ready session=session-123"
    assert Enum.at(lines, 2) == "| project=/project/ourocode"
    assert Enum.at(lines, 3) == "| cwd=/project/ourocode"
    assert Enum.at(lines, 4) == "+--"
  end

  test "clips long path/status lines inside the header width" do
    long_path = "/project/" <> String.duplicate("deeply-nested/", 12) <> "ourocode"

    area =
      HeaderStatusArea.render(%{
        status: :healthy,
        healthy?: true,
        context: %{
          project_dir: long_path,
          cwd: long_path,
          runtime: %{
            session_id: "session-" <> String.duplicate("x", 120),
            status: :streaming
          }
        }
      })

    lines =
      area
      |> HeaderStatusArea.render_text()
      |> String.split("\n")

    assert length(lines) == area.layout.rect.height
    assert Enum.all?(lines, &(String.length(&1) <= area.layout.rect.width))
  end
end
