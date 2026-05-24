defmodule Ourocode.Terminal.ScreenStylesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.ScreenStyles

  test "returns reset and SGR codes for screen styles" do
    assert ScreenStyles.reset() == "\e[0m"
    assert ScreenStyles.sgr(:text) == "\e[0m"
    assert ScreenStyles.sgr(:ok) == "\e[0;38;2;63;185;80m"
  end

  test "styled? treats text and nil as unstyled terminal state" do
    refute ScreenStyles.styled?(nil)
    refute ScreenStyles.styled?(:text)
    assert ScreenStyles.styled?(:warn)
  end
end
