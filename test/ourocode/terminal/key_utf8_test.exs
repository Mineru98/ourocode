defmodule Ourocode.Terminal.KeyUtf8Test do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.KeyUtf8

  test "takes complete multi-byte graphemes and returns the rest" do
    assert KeyUtf8.take("éx") == {:ok, "é", "x"}
    assert KeyUtf8.take("界x") == {:ok, "界", "x"}
    assert KeyUtf8.take("😀x") == {:ok, "😀", "x"}
  end

  test "reports incomplete sequences" do
    <<lead, _tail::binary>> = "界"

    assert KeyUtf8.take(<<>>) == :incomplete
    assert KeyUtf8.take(<<lead>>) == :incomplete
  end

  test "reports invalid lead bytes and invalid candidates" do
    assert KeyUtf8.take(<<0xC0, 0x80>>) == :invalid
    assert KeyUtf8.take(<<0xE2, ?(, 0xA1>>) == :invalid
  end
end
