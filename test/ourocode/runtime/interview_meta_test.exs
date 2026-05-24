defmodule Ourocode.Runtime.InterviewMetaTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewMeta

  test "merges response metadata from result, structured content, content annotations, and text json" do
    response = %{
      "result" => %{
        "meta" => %{"session_id" => "from-result", "keep" => true},
        "structuredContent" => %{
          "meta" => %{"session_id" => "from-structured"},
          "ambiguity_score" => "0.25"
        },
        "content" => [
          %{"annotations" => %{"meta" => %{"milestone" => "scope"}}}
        ]
      }
    }

    meta = InterviewMeta.response_meta(response, ~s({"seed_ready":true}))

    assert meta["session_id"] == "from-structured"
    assert meta["keep"]
    assert meta["ambiguity_score"] == "0.25"
    assert meta["milestone"] == "scope"
    assert meta["seed_ready"]
  end

  test "merges event metadata from event, payload, result, structured content, and content meta" do
    event = %{
      meta: %{"session_id" => "event"},
      payload: %{
        "meta" => %{"session_id" => "payload"},
        "result" => %{
          "_meta" => %{"milestone" => "result"},
          "structured_content" => %{"seed_ready" => false},
          "content" => [
            %{"meta" => %{"ambiguity_breakdown" => %{"scope" => 0.2}}}
          ]
        }
      }
    }

    meta = InterviewMeta.event_meta(event)

    assert meta["session_id"] == "payload"
    assert meta["milestone"] == "result"
    assert meta["seed_ready"] == false
    assert meta["ambiguity_breakdown"] == %{"scope" => 0.2}
  end

  test "looks up string and existing atom keys" do
    assert InterviewMeta.value(%{"session_id" => "string"}, "session_id") == "string"
    assert InterviewMeta.value(%{session_id: "atom"}, "session_id") == "atom"
    assert is_nil(InterviewMeta.value(%{}, "not_existing_interview_meta_key"))
  end

  test "normalizes numeric metadata values" do
    assert InterviewMeta.numeric_value(%{"score" => 1}, "score") == 1.0
    assert InterviewMeta.numeric_value(%{"score" => 0.5}, "score") == 0.5
    assert InterviewMeta.numeric_value(%{"score" => "0.75"}, "score") == 0.75
    assert is_nil(InterviewMeta.numeric_value(%{"score" => "none"}, "score"))
  end
end
