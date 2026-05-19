defmodule Ourocode.Dashboard.HeaderStatusAreaTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.HeaderStatusArea

  test "renders current app and session status as terminal-safe header text" do
    pane =
      HeaderStatusArea.render(%{
        status: :healthy,
        healthy?: true,
        context: %{
          project_dir: "/project/ourocode",
          cwd: "/project/ourocode",
          runtime: %{session_id: "session-123", status: :ready}
        }
      })

    assert pane.id == :header_status
    assert pane.kind == :terminal_header_status_area
    assert pane.status == :healthy
    assert pane.runtime_status == :ready
    assert pane.session_id == "session-123"

    text = HeaderStatusArea.render_text(pane)

    assert text =~ "+-- ourocode terminal"
    assert text =~ "| app=ourocode status=healthy runtime=ready session=session-123"
    assert text =~ "| project=/project/ourocode"
    assert text =~ "| cwd=/project/ourocode"
  end
end
