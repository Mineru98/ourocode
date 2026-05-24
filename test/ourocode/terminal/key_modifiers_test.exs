defmodule Ourocode.Terminal.KeyModifiersTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.KeyModifiers

  test "maps modified left and right arrows to word navigation" do
    assert KeyModifiers.arrow(?D, "1;3") == :alt_b
    assert KeyModifiers.arrow(?C, "1;3") == :alt_f
    assert KeyModifiers.arrow(?C, "1;5") == :alt_f
    assert KeyModifiers.arrow(?A, "1;3") == nil
    assert KeyModifiers.arrow(?D, "1;1") == nil
  end

  test "maps Kitty CSI-u modified keys" do
    assert KeyModifiers.key("127;9") == :cmd_backspace
    assert KeyModifiers.key("127;5") == :ctrl_backspace
    assert KeyModifiers.key("43;9") == :cmd_plus
    assert KeyModifiers.key("61;9") == :cmd_plus
    assert KeyModifiers.key("45;9") == :cmd_minus
  end

  test "maps xterm modifyOtherKeys sequences" do
    assert KeyModifiers.key("27;9;127") == :cmd_backspace
    assert KeyModifiers.key("27;9;43") == :cmd_plus
    assert KeyModifiers.key("27;9;45") == :cmd_minus
  end

  test "ignores unsupported or malformed modifier parameters" do
    assert KeyModifiers.key("127;1") == nil
    assert KeyModifiers.key("65;9") == nil
    assert KeyModifiers.key("not-a-key") == nil
  end
end
