defmodule Ourocode.WonderTool.SelectionPayloadTest do
  use ExUnit.Case, async: true

  alias Ourocode.WonderTool.SelectionPayload

  describe "extract_selections/1" do
    test "accepts singular and plural selection fields" do
      assert [2] = SelectionPayload.extract_selections(%{"selectedOption" => 2})
      assert ["A", "B"] = SelectionPayload.extract_selections(%{selected_options: ["A", "B"]})
      assert [1, 3] = SelectionPayload.extract_selections(%{"selections" => [1, nil, " ", 3]})
    end

    test "accepts bare values from UI handlers" do
      assert [1] = SelectionPayload.extract_selections(1)
      assert ["2"] = SelectionPayload.extract_selections("2")
      assert ["one", 2] = SelectionPayload.extract_selections(["one", nil, " ", 2])
    end

    test "returns an empty list when no selection field is present" do
      assert [] = SelectionPayload.extract_selections(%{"note" => "keep this separate"})
    end
  end

  test "extracts a trimmed question id" do
    assert "route" = SelectionPayload.question_id(%{"questionId" => " route "})
    assert nil == SelectionPayload.question_id(%{"questionId" => " "})
    assert nil == SelectionPayload.question_id(1)
  end

  test "extracts free-text and annotation aliases" do
    assert "custom answer" = SelectionPayload.free_text(%{"otherText" => " custom answer "})
    assert "annotate" = SelectionPayload.annotation(%{free_text_note: " annotate "})
  end
end
