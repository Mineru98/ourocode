defmodule Ourocode.Runtime.OuroborosSessionActivityContextTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.OuroborosSessionActivityContext

  test "builds activity context previews from persisted interview state" do
    context =
      OuroborosSessionActivityContext.build(%{
        "interview_id" => "interview_activity",
        "initial_context" => "ooo interview   improve\n  the right panel",
        "rounds" => [
          %{
            "round_number" => 1,
            "question" => "Which panel should surface the MCP reasoning?",
            "user_response" => nil
          }
        ]
      })

    assert context == %{
             session_id: "interview_activity",
             initial_context: "ooo interview improve the right panel",
             questions: %{1 => "Which panel should surface the MCP reasoning?"}
           }
  end

  test "omits empty context values" do
    assert OuroborosSessionActivityContext.build(%{"rounds" => []}) == %{}
  end

  test "normalizes and truncates long previews" do
    long_question = String.duplicate("word ", 30)

    context =
      OuroborosSessionActivityContext.build(%{
        rounds: [%{round_number: 1, question: long_question}]
      })

    assert %{questions: %{1 => preview}} = context
    assert String.ends_with?(preview, "...")
    assert byte_size(preview) <= 99
  end
end
