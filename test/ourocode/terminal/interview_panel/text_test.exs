defmodule Ourocode.Terminal.InterviewPanel.TextTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewPanel.Text

  test "md_text strips lightweight markdown and unstable glyphs" do
    assert Text.md_text("# **Hello** [there](https://example.com) `friend` 👋") ==
             "Hello there friend"
  end

  test "flatten_line normalizes markdown and whitespace" do
    assert Text.flatten_line("**Hello**\n\n`world`") == "Hello world"
  end

  test "plain_line only collapses whitespace" do
    assert Text.plain_line(" **Hello**\n world ") == "**Hello** world"
  end
end
