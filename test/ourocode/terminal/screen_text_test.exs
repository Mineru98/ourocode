defmodule Ourocode.Terminal.ScreenTextTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.ScreenText

  test "measures narrow and wide graphemes" do
    assert ScreenText.char_width("a") == 1
    assert ScreenText.char_width("界") == 2
    assert ScreenText.char_width("🙂") == 2
    assert ScreenText.text_width("a界🙂") == 5
  end

  test "measures modern Hangul syllables as wide cells" do
    syllables = hangul([0xC778, 0xD130, 0xBDF0])

    assert ScreenText.char_width(String.first(syllables)) == 2
    assert ScreenText.text_width(syllables) == 6
  end

  test "truncates by display columns without splitting wide graphemes" do
    assert ScreenText.truncate("abc", 2) == "ab"
    assert ScreenText.truncate("a界b", 2) == "a"
    assert ScreenText.truncate("a界b", 3) == "a界"
    assert ScreenText.truncate("a界b", 4) == "a界b"
    assert ScreenText.truncate("abc", 0) == ""
  end

  defp hangul(codepoints) do
    codepoints
    |> Enum.map(&<<&1::utf8>>)
    |> Enum.join()
  end
end
