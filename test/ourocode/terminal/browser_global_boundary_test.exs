defmodule Ourocode.Terminal.BrowserGlobalBoundaryTest do
  use ExUnit.Case, async: true

  @terminal_entry_files [
    "lib/ourocode/cli.ex",
    "lib/ourocode/terminal/application.ex",
    "lib/ourocode/terminal/root_ui.ex",
    "lib/ourocode/terminal/event_loop.ex",
    "lib/ourocode/terminal/shell_renderer.ex",
    "lib/ourocode/terminal/prompt_input_area.ex",
    "lib/ourocode/terminal/parent_child_pane_area.ex",
    "lib/ourocode/terminal/queued_notification_area.ex",
    "lib/ourocode/terminal/header_status_area.ex",
    "lib/ourocode/terminal/footer_state_area.ex"
  ]

  @browser_globals ~w(window document HTMLElement DOMParser)
  @browser_global_pattern Regex.compile!(
                            "(?<![A-Za-z0-9_?.!])(" <>
                              Enum.join(@browser_globals, "|") <>
                              ")(?![A-Za-z0-9_?.!])"
                          )

  test "terminal UI entry modules do not reference or import browser globals" do
    violations = browser_global_violations(@terminal_entry_files)

    assert violations == []
  end

  test "browser global scanner detects references and imports" do
    source_path = Path.join(System.tmp_dir!(), "ourocode-browser-global-#{unique_id()}.ex")

    File.write!(source_path, """
    defmodule BoundaryFixture do
      import DOMParser

      def run do
        window
        document
        HTMLElement
      end
    end
    """)

    assert [
             %{file: ^source_path, global: "DOMParser", line: 2},
             %{file: ^source_path, global: "window", line: 5},
             %{file: ^source_path, global: "document", line: 6},
             %{file: ^source_path, global: "HTMLElement", line: 7}
           ] = browser_global_violations([source_path])
  end

  defp browser_global_violations(paths) do
    paths
    |> Enum.flat_map(&browser_global_violations_for_file/1)
    |> Enum.sort_by(&{&1.file, &1.line, &1.global})
  end

  defp browser_global_violations_for_file(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      @browser_global_pattern
      |> Regex.scan(line)
      |> Enum.map(fn [_match, global] ->
        %{file: path, line: line_number, global: global, source: String.trim(line)}
      end)
    end)
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end
end
