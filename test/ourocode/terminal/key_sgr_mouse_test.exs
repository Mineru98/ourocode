defmodule Ourocode.Terminal.KeySgrMouseTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.KeySgrMouse

  test "decodes wheel reports and returns trailing bytes" do
    assert KeySgrMouse.parse("64;10;20Mtail") == {
             :ok,
             %{type: :mouse, key: :wheel_up, x: 10, y: 20},
             "tail"
           }

    assert KeySgrMouse.parse("65;3;4M") == {
             :ok,
             %{type: :mouse, key: :wheel_down, x: 3, y: 4},
             ""
           }
  end

  test "consumes non-wheel reports as other mouse input" do
    assert KeySgrMouse.parse("0;5;6M") == {
             :ok,
             %{type: :mouse, key: :other, x: nil, y: nil},
             ""
           }
  end

  test "reports incomplete and malformed SGR mouse input" do
    assert KeySgrMouse.parse("64;10") == :incomplete
    assert KeySgrMouse.parse("64:10:20M") == :ignore_one
  end
end
