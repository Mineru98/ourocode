defmodule Ourocode.Terminal.InputBufferTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InputBuffer

  test "normalizes pasted lines and image file URIs" do
    assert InputBuffer.normalize_paste("one\r\ntwo\rthree") == "one two three"

    assert InputBuffer.normalize_paste("file:///tmp/image%20one.PNG\nfile:///tmp/note.txt") ==
             "@image:/tmp/image one.PNG /tmp/note.txt"
  end

  test "inserts and deletes grapheme-safe text" do
    graphemes = String.graphemes("a한b")

    assert InputBuffer.insert_text(graphemes, 2, "🙂") ==
             {String.graphemes("a한🙂b"), 3}

    assert InputBuffer.delete_before(graphemes, 2) == {String.graphemes("ab"), 1}
    assert InputBuffer.delete_at(graphemes, 1) == {String.graphemes("ab"), 1}
  end

  test "moves across words and deletes before or after the cursor" do
    graphemes = String.graphemes("alpha  beta gamma")

    assert InputBuffer.word_before(graphemes, 12) == 7
    assert InputBuffer.word_after(graphemes, 5) == 11

    assert InputBuffer.delete_word_before(graphemes, 12) ==
             {String.graphemes("alpha  gamma"), 7}

    assert InputBuffer.delete_word_after(graphemes, 5) ==
             {String.graphemes("alpha gamma"), 5}
  end
end
