defmodule Ourocode.Terminal.StaticImportBoundaryTest do
  use ExUnit.Case, async: true

  @entry_modules [
    "Ourocode.CLI",
    "Ourocode.Terminal.Application",
    "Ourocode.Terminal.RootUI",
    "Ourocode.Terminal.EventLoop",
    "Ourocode.Terminal.ShellRenderer",
    "Ourocode.Terminal.PromptInputArea",
    "Ourocode.Terminal.ParentChildPaneArea",
    "Ourocode.Terminal.QueuedNotificationArea",
    "Ourocode.Terminal.HeaderStatusArea",
    "Ourocode.Terminal.FooterStateArea"
  ]

  @forbidden_browser_import_prefixes [
    "Bandit",
    "Browser",
    "Cowboy",
    "Desktop",
    "DOM",
    "DOMParser",
    "Document",
    "Electron",
    "HTMLElement",
    "Hound",
    "Ink",
    "Phoenix",
    "Playwright",
    "Plug",
    "Puppeteer",
    "React",
    "Selenium",
    "Tauri",
    "Wallaby",
    "Web.DOM",
    "Web.HTML",
    "Wry"
  ]

  test "baseline terminal UI dependency graph does not import browser-only packages or DOM adapters" do
    index = source_index()
    graph = reachable_local_graph(index, @entry_modules)

    violations =
      graph
      |> Enum.flat_map(fn {_module, source} ->
        source.imports
        |> Enum.filter(&forbidden_browser_import?/1)
        |> Enum.map(fn imported ->
          %{
            file: source.path,
            module: source.module,
            import: imported,
            line: source.import_lines[imported]
          }
        end)
      end)
      |> Enum.sort_by(&{&1.file, &1.line || 0, &1.import})

    assert violations == []
  end

  test "static import scanner detects browser and DOM adapter imports through local graph traversal" do
    entry_source = """
    defmodule BoundaryFixture.TerminalEntry do
      alias BoundaryFixture.SafePane
    end
    """

    pane_source = """
    defmodule BoundaryFixture.SafePane do
      import Phoenix.LiveView
      alias Web.DOM.Adapter
    end
    """

    entry_path = Path.join(System.tmp_dir!(), "ourocode-static-import-entry-#{unique_id()}.ex")
    pane_path = Path.join(System.tmp_dir!(), "ourocode-static-import-pane-#{unique_id()}.ex")
    File.write!(entry_path, entry_source)
    File.write!(pane_path, pane_source)
    Process.put(:static_import_fixture_paths, [entry_path, pane_path])

    index =
      %{}
      |> put_source("BoundaryFixture.TerminalEntry", entry_path, entry_source)
      |> put_source("BoundaryFixture.SafePane", pane_path, pane_source)

    violations =
      index
      |> reachable_local_graph(["BoundaryFixture.TerminalEntry"])
      |> Enum.flat_map(fn {_module, parsed_source} ->
        parsed_source.imports
        |> Enum.filter(&forbidden_browser_import?/1)
        |> Enum.map(&{parsed_source.module, &1})
      end)
      |> Enum.sort()

    assert violations == [
             {"BoundaryFixture.SafePane", "Phoenix.LiveView"},
             {"BoundaryFixture.SafePane", "Web.DOM.Adapter"}
           ]
  after
    if fixture_paths = Process.get(:static_import_fixture_paths) do
      Enum.each(fixture_paths, &File.rm/1)
    end
  end

  defp source_index do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn path, index ->
      source = File.read!(path)

      source
      |> module_names()
      |> Enum.reduce(index, &put_source(&2, &1, path, source))
    end)
  end

  defp put_source(index, module, path, source) do
    Map.put(index, module, %{
      module: module,
      path: path,
      imports: import_references(source),
      import_lines: import_reference_lines(source)
    })
  end

  defp module_names(source) do
    ~r/^\s*defmodule\s+([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\s+do/m
    |> Regex.scan(source)
    |> Enum.map(fn [_match, module] -> module end)
  end

  defp import_references(source) do
    source
    |> import_reference_lines()
    |> Map.keys()
    |> Enum.sort()
  end

  defp import_reference_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {line, line_number}, acc ->
      line
      |> import_modules_from_line()
      |> Enum.reduce(acc, &Map.put_new(&2, &1, line_number))
    end)
  end

  defp import_modules_from_line(line) do
    case Regex.run(~r/^\s*(?:alias|import|require|use)\s+(.+)$/, line) do
      nil ->
        []

      [_match, reference] ->
        reference
        |> String.split("#", parts: 2)
        |> hd()
        |> expand_module_reference()
    end
  end

  defp expand_module_reference(reference) do
    reference
    |> String.split(",", parts: 2)
    |> hd()
    |> String.trim()
    |> case do
      "" ->
        []

      reference ->
        case Regex.run(~r/^([A-Z][A-Za-z0-9_.]*)\.\{(.+)\}/, reference) do
          nil ->
            case Regex.run(~r/^([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)/, reference) do
              nil -> []
              [_match, module] -> [module]
            end

          [_match, prefix, suffixes] ->
            suffixes
            |> String.split(",")
            |> Enum.map(&(prefix <> "." <> String.trim(&1)))
        end
    end
  end

  defp reachable_local_graph(index, entry_modules) do
    visit_modules(index, :queue.from_list(entry_modules), MapSet.new(), %{})
  end

  defp visit_modules(index, queue, visited, graph) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        graph

      {{:value, module}, queue} ->
        cond do
          MapSet.member?(visited, module) ->
            visit_modules(index, queue, visited, graph)

          source = Map.get(index, module) ->
            next_modules = local_dependency_modules(index, source.imports)

            visit_modules(
              index,
              enqueue(queue, next_modules),
              MapSet.put(visited, module),
              Map.put(graph, module, source)
            )

          true ->
            visit_modules(index, queue, MapSet.put(visited, module), graph)
        end
    end
  end

  defp local_dependency_modules(index, imports) do
    imports
    |> Enum.flat_map(fn imported ->
      exact =
        if Map.has_key?(index, imported) do
          [imported]
        else
          []
        end

      descendants =
        index
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, imported <> "."))

      exact ++ descendants
    end)
    |> Enum.uniq()
  end

  defp enqueue(queue, modules) do
    Enum.reduce(modules, queue, &:queue.in/2)
  end

  defp forbidden_browser_import?(module) do
    Enum.any?(@forbidden_browser_import_prefixes, fn forbidden ->
      module == forbidden or String.starts_with?(module, forbidden <> ".")
    end)
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end
end
