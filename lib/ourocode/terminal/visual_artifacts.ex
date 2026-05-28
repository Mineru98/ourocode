defmodule Ourocode.Terminal.VisualArtifacts do
  @moduledoc false

  @asset_dir Path.join(["docs", "assets", "visual"])
  @hero_svg Path.join(["docs", "assets", "ourocode-readme-hero.svg"])
  @font_family "JetBrains Mono, SFMono-Regular, Menlo, Consolas, monospace"
  @width 1280
  @line_height 24
  @pad_x 36
  @pad_y 34
  @max_columns 76
  @palettes %{
    dark: %{
      background: "#0a0a0b",
      panel: "#111111",
      stroke: "#3a3a40",
      text: "#e2e2e5",
      muted: "#a8a8a8",
      accent: "#66d9c2",
      warn: "#e8a45c",
      danger: "#f87171",
      yellow: "#fbbf24"
    },
    light: %{
      background: "#fafaf9",
      panel: "#f2f2f0",
      stroke: "#d6d6d2",
      text: "#222226",
      muted: "#626268",
      accent: "#14665a",
      warn: "#996023",
      danger: "#b52a2a",
      yellow: "#9a6a12"
    }
  }

  @spec write(map(), keyword()) :: %{optional(atom()) => String.t()}
  def write(frames, opts \\ []) when is_map(frames) and is_list(opts) do
    asset_dir = Keyword.get(opts, :asset_dir, @asset_dir)
    hero_svg = Keyword.get(opts, :hero_svg, @hero_svg)

    File.mkdir_p!(asset_dir)

    frames
    |> Enum.map(fn {name, text} -> {name, write_frame(asset_dir, name, text)} end)
    |> Map.new()
    |> maybe_write_hero(frames, hero_svg)
  end

  defp write_frame(asset_dir, name, text) do
    path = Path.join(asset_dir, "#{name}.svg")
    File.write!(path, svg(to_string(text), title(name), theme_for(name)))
    path
  end

  defp maybe_write_hero(paths, frames, hero_svg) do
    case Map.get(frames, :pm_picker) do
      nil ->
        paths

      text ->
        File.mkdir_p!(Path.dirname(hero_svg))
        File.write!(hero_svg, svg(to_string(text), "Ourocode PM picker", :dark))
        Map.put(paths, :readme_hero, hero_svg)
    end
  end

  defp svg(text, title, theme) do
    palette = Map.fetch!(@palettes, theme)

    lines =
      text
      |> String.split("\n")
      |> Enum.flat_map(&wrap_line/1)

    height = min(max(length(lines) * @line_height + @pad_y * 2 + 28, 560), 1100)
    visible_lines = Enum.take(lines, max(div(height - @pad_y * 2, @line_height), 1))

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{height}" viewBox="0 0 #{@width} #{height}">
      <title>#{escape(title)}</title>
      <rect width="100%" height="100%" rx="24" fill="#{palette.background}"/>
      <rect x="18" y="18" width="#{@width - 36}" height="#{height - 36}" rx="18" fill="#{palette.panel}" stroke="#{palette.stroke}"/>
      <circle cx="46" cy="45" r="6" fill="#{palette.danger}"/>
      <circle cx="68" cy="45" r="6" fill="#{palette.yellow}"/>
      <circle cx="90" cy="45" r="6" fill="#{palette.accent}"/>
      <text x="112" y="51" fill="#{palette.accent}" font-family="#{@font_family}" font-size="16" font-weight="700">ourocode</text>
      #{render_lines(visible_lines, palette)}
    </svg>
    """
  end

  defp render_lines(lines, palette) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      y = @pad_y + 58 + index * @line_height

      ~s(<text x="#{@pad_x}" y="#{y}" fill="#{line_color(line, palette)}" font-family="#{@font_family}" font-size="15">#{escape(line)}</text>)
    end)
    |> Enum.join("\n  ")
  end

  defp wrap_line(""), do: [""]

  defp wrap_line(line) do
    if String.length(line) <= @max_columns do
      [line]
    else
      {indent, content} = split_indent(line)

      content
      |> wrap_words(@max_columns - String.length(indent), [])
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        prefix = if index == 0, do: indent, else: indent <> "  "
        prefix <> chunk
      end)
    end
  end

  defp split_indent(line) do
    indent = Regex.run(~r/^\s*/, line) |> List.first()
    {indent, String.trim_leading(line)}
  end

  defp wrap_words(content, width, acc) when width < 20 do
    wrap_words(content, 20, acc)
  end

  defp wrap_words(content, width, _acc) do
    content
    |> String.split(" ")
    |> Enum.reduce([""], fn word, [current | rest] ->
      cond do
        current == "" ->
          [word | rest]

        String.length(current) + 1 + String.length(word) <= width ->
          [current <> " " <> word | rest]

        true ->
          [word, current | rest]
      end
    end)
    |> Enum.reverse()
  end

  defp line_color(line, palette) do
    cond do
      String.contains?(line, ["●", ">>", "passed", "ready", "active"]) ->
        palette.accent

      String.contains?(line, ["INTERVIEW", "workspace", "capture", "theme"]) ->
        palette.warn

      String.starts_with?(String.trim_leading(line), [
        "Actions",
        "Shortcuts",
        "Use",
        "Keys",
        "Start",
        "Run",
        "Move",
        "Next"
      ]) ->
        palette.muted

      String.trim(line) == "" ->
        palette.text

      true ->
        palette.text
    end
  end

  defp theme_for(name) when name in [:theme_light, :light, :first_start_light], do: :light
  defp theme_for(_name), do: :dark

  defp title(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
