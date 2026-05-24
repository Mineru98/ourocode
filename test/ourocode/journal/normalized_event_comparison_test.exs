defmodule Ourocode.Journal.NormalizedEventComparisonTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.NormalizedEventComparison

  test "compare ignores diagnostic raw_event metadata" do
    journaled = [%{event_seq: 1, type: :parent_call_event, raw_event: %{debug: "journal"}}]
    source = [%{event_seq: 1, type: :parent_call_event, raw_event: %{debug: "source"}}]

    assert {:ok, %{status: :ok, mismatched_count: 0}} =
             NormalizedEventComparison.compare(journaled, source)
  end

  test "compare reports missing, extra, and mismatched normalized events" do
    journaled = [
      %{event_seq: 1, type: :parent_call_event, payload: %{token: "changed"}},
      %{event_seq: 3, type: :parent_call_event, payload: %{token: "extra"}}
    ]

    source = [
      %{event_seq: 1, type: :parent_call_event, payload: %{token: "source"}},
      %{event_seq: 2, type: :parent_call_event, payload: %{token: "missing"}}
    ]

    assert {:error,
            %{
              status: :failed,
              missing_count: 1,
              extra_count: 1,
              mismatched_count: 1,
              reason: :normalized_event_no_loss_comparison_failed,
              missing_normalized_events: [%{identity: %{kind: :event_seq, value: 2}}],
              extra_normalized_events: [%{identity: %{kind: :event_seq, value: 3}}],
              mismatched_normalized_events: [
                %{identity: %{kind: :event_seq, value: 1}, differing_fields: ["payload"]}
              ]
            }} = NormalizedEventComparison.compare(journaled, source)
  end
end
