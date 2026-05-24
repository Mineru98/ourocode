defmodule Ourocode.Terminal.KeySequenceTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.KeySequence

  test "decodes CSI arrows, navigation keys, and remaining tail" do
    assert KeySequence.csi("Arest") == {:ok, key(:up), "rest"}
    assert KeySequence.csi("3~tail") == {:ok, key(:delete), "tail"}
    assert KeySequence.csi("5~tail") == {:ok, key(:page_up), "tail"}
    assert KeySequence.csi("6~tail") == {:ok, key(:page_down), "tail"}
  end

  test "decodes modified arrows and modified keys" do
    assert KeySequence.csi("1;3D") == {:ok, key(:alt_b), ""}
    assert KeySequence.csi("1;3C") == {:ok, key(:alt_f), ""}
    assert KeySequence.csi("127;9u") == {:ok, key(:cmd_backspace), ""}
    assert KeySequence.csi("27;9;43~") == {:ok, key(:cmd_plus), ""}
    assert KeySequence.csi("27;9;45~") == {:ok, key(:cmd_minus), ""}
  end

  test "decodes bracketed paste and waits for the closing marker" do
    assert KeySequence.csi("200~hello\n/tmp/image.png\e[201~tail") ==
             {:ok, %{type: :key, key: :paste, char: "hello\n/tmp/image.png"}, "tail"}

    assert KeySequence.csi("200~partial") == :incomplete
  end

  test "decodes SS3 application cursor arrows" do
    assert KeySequence.ss3(?A) == {:ok, key(:up)}
    assert KeySequence.ss3(?D) == {:ok, key(:left)}
    assert KeySequence.ss3(?X) == :error
  end

  test "decodes SGR mouse wheel reports and incomplete reports" do
    assert KeySequence.csi("<64;10;20Mtail") == {
             :ok,
             %{type: :mouse, key: :wheel_up, x: 10, y: 20},
             "tail"
           }

    assert KeySequence.csi("<65;3;4M") == {
             :ok,
             %{type: :mouse, key: :wheel_down, x: 3, y: 4},
             ""
           }

    assert KeySequence.csi("<64;10") == :incomplete
  end

  defp key(name), do: %{type: :key, key: name, char: nil}
end
