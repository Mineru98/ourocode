defmodule Ourocode.Runtime.LoopBindingInterviewTextTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.LoopBindingInterviewText

  test "initial_context_from_payload reads string-keyed payloads" do
    payload = %{
      "params" => %{
        "arguments" => %{
          "initial_context" => "Improve onboarding"
        }
      }
    }

    assert LoopBindingInterviewText.initial_context_from_payload(payload) == "Improve onboarding"
  end

  test "initial_context_from_payload reads atom-keyed payloads and ignores blanks" do
    payload = %{
      params: %{
        arguments: %{
          initial_context: "  "
        }
      }
    }

    assert LoopBindingInterviewText.initial_context_from_payload(payload) == ""

    payload = put_in(payload, [:params, :arguments, :initial_context], "Plan the refactor")
    assert LoopBindingInterviewText.initial_context_from_payload(payload) == "Plan the refactor"
  end

  test "user_terminated? detects terminal answers case-insensitively" do
    for text <- ["done", " Done ", "cancel", "STOP", "/cancel"] do
      assert LoopBindingInterviewText.user_terminated?(text)
    end

    refute LoopBindingInterviewText.user_terminated?("continue")
  end

  test "ensure_user_prefix preserves existing source prefixes" do
    assert LoopBindingInterviewText.ensure_user_prefix(" answer ") == "[from-user] answer"

    assert LoopBindingInterviewText.ensure_user_prefix("[from-main] answer") ==
             "[from-main] answer"
  end

  test "streak_after resets on user answers and increments otherwise" do
    assert LoopBindingInterviewText.streak_after(3, :user) == 0
    assert LoopBindingInterviewText.streak_after(3, :model) == 4
  end
end
