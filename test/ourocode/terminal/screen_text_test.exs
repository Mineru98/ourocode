defmodule Ourocode.Terminal.ScreenTextTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.ScreenText

  test "measures narrow and wide graphemes" do
    assert ScreenText.char_width("a") == 1
    assert ScreenText.char_width("한") == 2
    assert ScreenText.char_width("🙂") == 2
    assert ScreenText.text_width("a한🙂") == 5
  end

  test "truncates by display columns without splitting wide graphemes" do
    assert ScreenText.truncate("abc", 2) == "ab"
    assert ScreenText.truncate("a한b", 2) == "a"
    assert ScreenText.truncate("a한b", 3) == "a한"
    assert ScreenText.truncate("a한b", 4) == "a한b"
    assert ScreenText.truncate("abc", 0) == ""
  end
end
