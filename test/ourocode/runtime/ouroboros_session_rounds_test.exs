defmodule Ourocode.Runtime.OuroborosSessionRoundsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.OuroborosSessionRounds

  test "summarizes answered and pending persisted rounds" do
    assert OuroborosSessionRounds.summarize([
             %{"round_number" => 1, "question" => "First?", "user_response" => "yes"},
             %{"round_number" => 2, "question" => "Second?", "user_response" => nil}
           ]) == %{
             answered_rounds: 1,
             total_rounds: 2,
             pending_question?: true,
             last_question: "Second?"
           }
  end

  test "treats blank responses as unanswered and non-empty non-binary responses as answered" do
    assert OuroborosSessionRounds.summarize([
             %{question: "First?", user_response: "  "},
             %{question: "Second?", user_response: true}
           ]) == %{
             answered_rounds: 1,
             total_rounds: 2,
             pending_question?: false,
             last_question: "Second?"
           }
  end

  test "handles missing or non-list rounds as an empty summary" do
    assert OuroborosSessionRounds.summarize(nil) == %{
             answered_rounds: 0,
             total_rounds: 0,
             pending_question?: false,
             last_question: nil
           }
  end
end
