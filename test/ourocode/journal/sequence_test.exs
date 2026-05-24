defmodule Ourocode.Journal.SequenceTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.Sequence

  test "assigns first event_seq when record and journal entries have no sequence" do
    assert Sequence.event_seq_for_append(%{"type" => "event"}, []) == {:ok, 1}
  end

  test "assigns next event_seq from mixed atom and string keyed entries" do
    entries = [
      %{event_seq: 2},
      %{"event_seq" => 5},
      %{event_seq: "ignored"},
      %{"event_seq" => nil}
    ]

    assert Sequence.event_seq_for_append(%{"type" => "event"}, entries) == {:ok, 6}
    assert Sequence.next_event_seq_from_entries(entries) == 6
  end

  test "accepts explicit integer event_seq for an empty journal" do
    assert Sequence.event_seq_for_append(%{"event_seq" => 42}, []) == {:ok, 42}
  end

  test "accepts explicit contiguous event_seq for an existing journal" do
    entries = [%{event_seq: 1}, %{"event_seq" => 2}]

    assert Sequence.event_seq_for_append(%{"event_seq" => 3}, entries) == {:ok, 3}
  end

  test "rejects explicit event_seq gaps" do
    entries = [%{event_seq: 1}, %{"event_seq" => 2}]

    assert Sequence.event_seq_for_append(%{"event_seq" => 5}, entries) ==
             {:error, {:event_seq_gap, 3, 5}}
  end

  test "rejects non-integer explicit event_seq" do
    assert Sequence.event_seq_for_append(%{"event_seq" => "3"}, []) ==
             {:error, {:invalid_event_seq, "3"}}
  end
end
