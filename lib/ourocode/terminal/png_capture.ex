defmodule Ourocode.Terminal.PngCapture do
  @moduledoc false

  @cell_w 8
  @cell_h 16
  @glyph_w 5
  @glyph_h 10

  @palettes %{
    dark: %{
      background: {10, 10, 11},
      text: {226, 226, 229},
      accent: {102, 217, 194},
      warn: {232, 164, 92},
      muted: {168, 168, 168}
    },
    light: %{
      background: {250, 250, 249},
      text: {34, 34, 38},
      accent: {20, 102, 90},
      warn: {153, 96, 35},
      muted: {98, 98, 104}
    }
  }

  @type rgb :: {0..255, 0..255, 0..255}

  @spec write_png([String.t()], Path.t(), :dark | :light) :: map()
  def write_png(lines, path, theme \\ :dark) when is_list(lines) and is_binary(path) do
    case write_font_png(lines, path, theme) do
      {:ok, meta} -> meta
      :error -> write_block_png(lines, path, theme)
    end
  end

  defp write_font_png(lines, path, theme) do
    payload_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-png-payload-#{System.unique_integer([:positive])}.json"
      )

    try do
      with python when is_binary(python) <- System.find_executable("python3"),
           script when is_binary(script) <- render_script_path(),
           true <- File.exists?(script),
           payload <-
             IO.iodata_to_binary(
               Ourocode.Json.encode!(%{lines: lines, path: path, theme: Atom.to_string(theme)})
             ),
           :ok <- File.write(payload_path, payload),
           {output, 0} <- System.cmd(python, [script, payload_path], stderr_to_stdout: true),
           {:ok, %{} = decoded} <- Ourocode.Json.decode(output) do
        {:ok, decode_font_meta(decoded)}
      else
        _other -> :error
      end
    after
      File.rm(payload_path)
    end
  rescue
    _exception -> :error
  end

  defp render_script_path do
    File.cwd!()
    |> Path.join("scripts/render_text_png.py")
  end

  defp decode_font_meta(meta) do
    %{
      path: meta["path"],
      width: meta["width"],
      height: meta["height"],
      bytes: meta["bytes"],
      background_rgb: rgb_tuple(meta["background_rgb"]),
      non_background_pixels: meta["non_background_pixels"],
      accent_pixels: meta["accent_pixels"],
      top_left_rgb: rgb_tuple(meta["top_left_rgb"]),
      center_rgb: rgb_tuple(meta["center_rgb"]),
      renderer: meta["renderer"]
    }
  end

  defp rgb_tuple([r, g, b]), do: {r, g, b}

  defp write_block_png(lines, path, theme) do
    palette = Map.fetch!(@palettes, theme)
    cols = lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 1 end) |> max(1)
    rows = max(length(lines), 1)
    width = cols * @cell_w
    height = rows * @cell_h
    background = palette.background

    colored =
      lines
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {line, row}, acc ->
        line
        |> String.graphemes()
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {char, col}, inner ->
          draw_char(inner, width, col, row, char, color_for(line, char, palette))
        end)
      end)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, png(width, height, background, colored))

    %{
      path: path,
      width: width,
      height: height,
      bytes: File.stat!(path).size,
      background_rgb: background,
      non_background_pixels: map_size(colored),
      accent_pixels: colored |> Map.values() |> Enum.count(&(&1 == palette.accent)),
      top_left_rgb: Map.get(colored, 0, background),
      center_rgb: Map.get(colored, div(width * height, 2), background),
      renderer: "block"
    }
  end

  defp draw_char(colored, _width, _col, _row, " ", _color), do: colored
  defp draw_char(colored, _width, _col, _row, "", _color), do: colored

  defp draw_char(colored, width, col, row, _char, color) do
    x0 = col * @cell_w + 1
    y0 = row * @cell_h + 3

    for y <- y0..(y0 + @glyph_h - 1),
        x <- x0..(x0 + @glyph_w - 1),
        reduce: colored do
      acc -> Map.put(acc, y * width + x, color)
    end
  end

  defp color_for(line, char, palette) do
    cond do
      char in ["●", "○", ">", "│", "*"] ->
        palette.accent

      String.contains?(line, ["INTERVIEW", "workspace", "capture"]) ->
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

      true ->
        palette.text
    end
  end

  defp png(width, height, background, colored) do
    raw =
      0..(height - 1)
      |> Enum.map(fn y ->
        row =
          0..(width - 1)
          |> Enum.map(fn x ->
            colored
            |> Map.get(y * width + x, background)
            |> Tuple.to_list()
          end)

        [0 | row]
      end)
      |> IO.iodata_to_binary()

    [
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      chunk("IHDR", <<width::32, height::32, 8, 2, 0, 0, 0>>),
      chunk("IDAT", :zlib.compress(raw)),
      chunk("IEND", "")
    ]
    |> IO.iodata_to_binary()
  end

  defp chunk(type, data) do
    body = type <> data
    [<<byte_size(data)::32>>, body, <<:erlang.crc32(body)::32>>]
  end
end
