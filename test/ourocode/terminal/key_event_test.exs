defmodule Ourocode.Terminal.KeyEventTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.KeyEvent

  test "key builds normalized key events" do
    assert KeyEvent.key(:enter) == %{type: :key, key: :enter, char: nil}
  end

  test "char builds printable character events" do
    assert KeyEvent.char("界") == %{type: :key, key: :char, char: "界"}
  end

  test "paste builds bracketed paste events" do
    assert KeyEvent.paste("hello\nworld") == %{type: :key, key: :paste, char: "hello\nworld"}
  end

  test "mouse builds normalized mouse events" do
    assert KeyEvent.mouse(:wheel_up, 10, 20) == %{type: :mouse, key: :wheel_up, x: 10, y: 20}
  end
end
