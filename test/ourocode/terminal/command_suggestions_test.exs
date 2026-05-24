defmodule Ourocode.Terminal.CommandSuggestionsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry
  alias Ourocode.Terminal.CommandSuggestions

  test "computes edit distance over graphemes" do
    assert CommandSuggestions.edit_distance("status", "status") == 0
    assert CommandSuggestions.edit_distance("capabilites", "capabilities") == 1
    assert CommandSuggestions.edit_distance("도움", "도무") == 1
  end

  test "suggests nearby canonical slashes from command names and aliases" do
    {:ok, registry} = Registry.load_builtin()

    assert "/capabilities" in CommandSuggestions.suggestions(registry, "/capabilites")
    assert "/help" in CommandSuggestions.suggestions(registry, "/h")

    assert {:unknown_command, "/capabilites", suggestions} =
             CommandSuggestions.unknown_reason("/capabilites", registry)

    assert "/capabilities" in suggestions
    assert length(suggestions) <= 3
  end

  test "deduplicates canonical slash suggestions and ignores distant commands" do
    {:ok, registry} = Registry.load_builtin()

    suggestions = CommandSuggestions.suggestions(registry, "/zzzzzzzzzzzzzz")

    assert suggestions == Enum.uniq(suggestions)
    assert suggestions == []
  end
end
