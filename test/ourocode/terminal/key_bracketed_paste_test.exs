defmodule Ourocode.Terminal.KeyBracketedPasteTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.KeyBracketedPaste

  test "extracts pasted text and trailing bytes" do
    assert KeyBracketedPaste.parse("hello\n/tmp/image.png\e[201~tail") == {
             :ok,
             %{type: :key, key: :paste, char: "hello\n/tmp/image.png"},
             "tail"
           }
  end

  test "allows empty paste payloads" do
    assert KeyBracketedPaste.parse("\e[201~tail") == {
             :ok,
             %{type: :key, key: :paste, char: ""},
             "tail"
           }
  end

  test "waits for the closing marker" do
    assert KeyBracketedPaste.parse("partial") == :incomplete
  end
end
