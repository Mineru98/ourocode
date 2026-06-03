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

  test "decodes button and hover reports" do
    assert KeySgrMouse.parse("0;5;6M") == {
             :ok,
             %{type: :mouse, key: :mouse_down, x: 5, y: 6},
             ""
           }

    assert KeySgrMouse.parse("35;7;8M") == {
             :ok,
             %{type: :mouse, key: :mouse_move, x: 7, y: 8},
             ""
           }

    assert KeySgrMouse.parse("0;5;6m") == {
             :ok,
             %{type: :mouse, key: :mouse_release, x: 5, y: 6},
             ""
           }
  end

  test "reports incomplete and malformed SGR mouse input" do
    assert KeySgrMouse.parse("64;10") == :incomplete
    assert KeySgrMouse.parse("64:10:20M") == :ignore_one
  end
end
