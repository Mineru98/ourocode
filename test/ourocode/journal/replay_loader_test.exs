defmodule Ourocode.Journal.ReplayLoaderTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.Journal.ReplayLoader

  test "recovers every journaled normalized event after an interrupted session without skips or duplicates" do
    path = journal_path("replay-loader-interrupted-session")

    source_events = [
      %{
        type: :parent_call_started,
        parent_call_id: "parent-replay-loader-1",
        runtime_source: "synthetic-runtime",
        transport: :stdio,
        occurred_at_ms: 1_001,
        method: "tools/call",
        params: %{"name" => "spawn_child"}
      },
      %{
        type: :parent_call_event,
        parent_call_id: "parent-replay-loader-1",
        runtime_source: "synthetic-runtime",
        transport: :sse,
        external_ids: %{"childID" => "child-replay-loader-1"},
        occurred_at_ms: 1_002,
        payload: %{"seq" => 1, "token" => "duplicate-visible-token"}
      },
      %{
        type: :parent_call_event,
        parent_call_id: "parent-replay-loader-1",
        runtime_source: "synthetic-runtime",
        transport: :sse,
        external_ids: %{"childID" => "child-replay-loader-1"},
        occurred_at_ms: 1_003,
        payload: %{"seq" => 2, "token" => "duplicate-visible-token"}
      },
      %{
        type: :parent_call_result,
        parent_call_id: "parent-replay-loader-1",
        runtime_source: "synthetic-runtime",
        transport: :streamable_http,
        external_ids: %{"childID" => "child-replay-loader-1"},
        occurred_at_ms: 1_004,
        result: %{"status" => "completed"}
      }
    ]

    emitted_events =
      Enum.map(source_events, fn event ->
        assert {:ok, emitted_event} = Journal.append_returning_event(path, event)
        emitted_event
      end)

    assert {:ok, %{events: recovered_events, report: report}} = ReplayLoader.load(path)

    assert recovered_events == emitted_events
    assert report.status == :ok
    assert report.persisted_record_count == 4
    assert report.recovered_event_count == 4
    assert report.recovered_event_seqs == [1, 2, 3, 4]
    assert report.expected_event_seqs == [1, 2, 3, 4]
    assert report.missing_event_seqs == []
    assert report.duplicate_event_seqs == []
    assert report.skipped_event_count == 0
    assert report.duplicated_event_count == 0

    assert Enum.map(recovered_events, & &1.transport) == [
             :stdio,
             :sse,
             :sse,
             :streamable_http
           ]

    assert Enum.map(Enum.slice(recovered_events, 1, 2), &get_in(&1, [:payload, "token"])) == [
             "duplicate-visible-token",
             "duplicate-visible-token"
           ]
  end

  test "replayed normalized events exactly match the persisted journal sequence including payload identity" do
    path = journal_path("replay-loader-persisted-sequence-identity")

    source_events = [
      %{
        type: :parent_call_event,
        parent_call_id: "parent-replay-identity",
        runtime_source: "synthetic-runtime",
        transport: :stdio,
        external_ids: %{"childID" => "child-replay-identity"},
        occurred_at_ms: 2_001,
        payload: %{
          "seq" => 1,
          "token" => "same-visible-token",
          "fragments" => [%{"index" => 1, "text" => "alpha"}]
        }
      },
      %{
        type: :parent_call_event,
        parent_call_id: "parent-replay-identity",
        runtime_source: "synthetic-runtime",
        transport: :sse,
        external_ids: %{"childID" => "child-replay-identity"},
        occurred_at_ms: 2_002,
        payload: %{
          "seq" => 2,
          "token" => "same-visible-token",
          "fragments" => [%{"index" => 2, "text" => "beta"}]
        }
      },
      %{
        type: :parent_call_result,
        parent_call_id: "parent-replay-identity",
        runtime_source: "synthetic-runtime",
        transport: :streamable_http,
        external_ids: %{"childID" => "child-replay-identity"},
        occurred_at_ms: 2_003,
        result: %{"status" => "completed", "payload_sha" => "sha256:identity"}
      }
    ]

    Enum.each(source_events, fn event ->
      assert {:ok, _persisted_event} = Journal.append_returning_event(path, event)
    end)

    assert {:ok, persisted_journal_sequence} = Journal.read_ordered(path)
    assert {:ok, %{events: replayed_events, report: report}} = ReplayLoader.load(path)

    assert replayed_events == persisted_journal_sequence
    assert Enum.map(replayed_events, & &1.event_seq) == [1, 2, 3]
    assert Enum.map(replayed_events, & &1.transport) == [:stdio, :sse, :streamable_http]

    persisted_payloads =
      Enum.map(persisted_journal_sequence, fn event ->
        Map.get(event, :payload) || Map.get(event, :result)
      end)

    replayed_payloads =
      Enum.map(replayed_events, fn event ->
        Map.get(event, :payload) || Map.get(event, :result)
      end)

    assert replayed_payloads == persisted_payloads
    assert Enum.at(replayed_payloads, 0) != Enum.at(replayed_payloads, 1)
    assert get_in(Enum.at(replayed_payloads, 0), ["fragments", Access.at(0), "text"]) == "alpha"
    assert get_in(Enum.at(replayed_payloads, 1), ["fragments", Access.at(0), "text"]) == "beta"

    assert report.persisted_record_count == length(persisted_journal_sequence)
    assert report.recovered_event_count == length(replayed_events)
    assert report.recovered_event_seqs == Enum.map(persisted_journal_sequence, & &1.event_seq)
  end

  test "rejects replay streams that would skip a persisted event sequence" do
    events = [
      %{event_seq: 1, type: :parent_call_event},
      %{event_seq: 3, type: :parent_call_event}
    ]

    assert {:error,
            %{
              status: :failed,
              reason: :journal_replay_event_seq_not_contiguous,
              persisted_record_count: 2,
              recovered_event_count: 2,
              expected_event_seqs: [1, 2],
              recovered_event_seqs: [1, 3],
              missing_event_seqs: [2],
              duplicate_event_seqs: []
            }} = ReplayLoader.verify_recovery(events, 2)
  end

  test "rejects replay streams that would duplicate a persisted event sequence" do
    events = [
      %{event_seq: 1, type: :parent_call_event},
      %{event_seq: 2, type: :parent_call_event},
      %{event_seq: 2, type: :parent_call_event}
    ]

    assert {:error,
            %{
              status: :failed,
              reason: :journal_replay_event_seq_not_contiguous,
              persisted_record_count: 3,
              recovered_event_count: 3,
              expected_event_seqs: [1, 2, 3],
              recovered_event_seqs: [1, 2, 2],
              missing_event_seqs: [3],
              duplicate_event_seqs: [2]
            }} = ReplayLoader.verify_recovery(events, 3)
  end

  defp journal_path(name) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")

    File.rm(path)
    path
  end
end
