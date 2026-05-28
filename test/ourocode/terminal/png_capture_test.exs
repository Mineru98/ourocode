defmodule Ourocode.Terminal.PngCaptureTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.PngCapture

  test "writes a PNG and reports pixel evidence" do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-png-capture-#{System.unique_integer([:positive])}.png"
      )

    on_exit(fn -> File.rm(path) end)

    meta =
      PngCapture.write_png(
        [
          "ourocode",
          "● ooo pm <goal>",
          "INTERVIEW"
        ],
        path,
        :dark
      )

    assert File.exists?(path)
    assert File.read!(path) |> String.starts_with?(<<137, 80, 78, 71, 13, 10, 26, 10>>)
    assert meta.width > 0
    assert meta.height == 48
    assert meta.bytes > 100
    assert meta.background_rgb == {10, 10, 11}
    assert meta.top_left_rgb == {10, 10, 11}
    assert meta.non_background_pixels > 0
    assert meta.accent_pixels > 0
  end
end
