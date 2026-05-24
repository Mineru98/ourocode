defmodule Ourocode.Runtime.InterviewRouter.DirectiveTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewRouter.Directive

  test "parses tool directives" do
    assert Directive.parse("TOOL READ mix.exs") == {:tool, :read, "mix.exs"}
    assert Directive.parse("TOOL GLOB lib/**/*.ex") == {:tool, :glob, "lib/**/*.ex"}

    assert Directive.parse("TOOL GREP defmodule lib/**/*.ex") ==
             {:tool, :grep, "defmodule lib/**/*.ex"}
  end

  test "parses answer directives with multiline payload" do
    assert Directive.parse("""
           ANSWER [from-code] The app is Elixir.
           It uses Mix.
           """) == {:answer, "[from-code] The app is Elixir.\nIt uses Mix."}
  end

  test "parses ask-user directives with suggested options" do
    assert Directive.parse("""
           ASK_USER Which scope should we take?
           - Small | Touch one module
           - Broad | Include related runtime paths
           """) ==
             {:ask_user, "Which scope should we take?",
              [
                %{label: "Small", description: "Touch one module"},
                %{label: "Broad", description: "Include related runtime paths"}
              ]}
  end

  test "expands inline ask-user options" do
    assert Directive.parse(
             "ASK_USER Pick scope - Small | One module - Broad | Related runtime paths"
           ) ==
             {:ask_user, "Pick scope",
              [
                %{label: "Small", description: "One module"},
                %{label: "Broad", description: "Related runtime paths"}
              ]}
  end

  test "finds first directive after echoed prompt and drops cli footer" do
    wrapped = """
    runner banner
    ## Your reply
    ignored prompt copy
    ANSWER [from-code] Existing architecture is modular.
    tokens used
    123
    """

    assert Directive.parse(wrapped) ==
             {:answer, "[from-code] Existing architecture is modular."}
  end

  test "returns unparseable for prose" do
    assert Directive.parse("I think we should ask the user") == :unparseable
    assert Directive.parse(nil) == :unparseable
  end
end
