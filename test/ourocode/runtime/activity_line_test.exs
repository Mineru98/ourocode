defmodule Ourocode.Runtime.ActivityLineTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.ActivityLine

  test "enriches interview start lines with persisted initial context" do
    assert ActivityLine.enrich("interview started · 39 chars", %{
             initial_context: "ooo interview improve the right panel"
           }) ==
             "interview started · initial: ooo interview improve the right panel"
  end

  test "does not add initial context twice" do
    line = "interview started · initial: already present"

    assert ActivityLine.enrich(line, %{initial_context: "ignored"}) == line
  end

  test "replaces generated question activity with persisted question text" do
    assert ActivityLine.enrich("round 2 · question generated", %{
             questions: %{2 => "Which panel should change?"}
           }) == "round 2 · question: Which panel should change?"
  end

  test "keeps unknown generated questions unchanged" do
    line = "round 2 · question generated"

    assert ActivityLine.enrich(line, %{questions: %{}}) == line
  end

  test "dedupes normalized activity lines keeping the latest equivalent line" do
    assert ActivityLine.dedupe([
             "activity: interview started · 39 chars",
             "interview started",
             "round 1 · question generated",
             "activity: round 1 · question generated"
           ]) == [
             "interview started",
             "activity: round 1 · question generated"
           ]
  end
end
