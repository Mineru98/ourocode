defmodule Ourocode.MCP.Transport.SSEJournalIntegrationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.Json
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.SSE
  alias Ourocode.MCP.Transport.SSE.{LifecycleNormalizer, Parser}

  test "SSE journal replay reconstructs canonical normalized events with raw metadata" do
    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-sse-canonical-journal-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(journal_path) end)

    raw_frame =
      sse_frame(
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "childID" => "child-sse-canonical-1",
            "seq" => 1,
            "token" => "canonical-token"
          }
        },
        event: "child-token",
        id: "sse-raw-frame-1"
      )
      |> IO.iodata_to_binary()

    assert {:ok, [parsed_event], ""} = Parser.parse_complete_frames(raw_frame)

    normalized_event =
      LifecycleNormalizer.normalize_parsed_event(parsed_event, %{
        event_seq: 1,
        parent_call_id: "parent-sse-canonical-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-sse-canonical-1"},
        occurred_at_ms: 123,
        status: 200,
        headers: [{"content-type", "text/event-stream"}]
      })

    assert %LifecycleEvent{
             type: :parent_call_event,
             transport: :sse,
             parent_call_id: "parent-sse-canonical-1",
             raw_event: %{
               "event" => "child-token",
               "id" => "sse-raw-frame-1",
               "data" => %{"method" => "notifications/progress"}
             }
           } = normalized_event

    assert :ok = Journal.append(journal_path, SSE.canonical_journal_event(normalized_event))

    assert {:ok, [journaled_event]} = Journal.replay_normalized_events(journal_path)

    assert %{
             type: :parent_call_event,
             transport: :sse,
             parent_call_id: "parent-sse-canonical-1",
             runtime_source: "synthetic",
             payload: %{
               "childID" => "child-sse-canonical-1",
               "seq" => 1,
               "token" => "canonical-token"
             },
             notification: %{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{
                 "childID" => "child-sse-canonical-1",
                 "seq" => 1,
                 "token" => "canonical-token"
               }
             }
           } = journaled_event

    assert journaled_event.raw_event == normalized_event.raw_event

    assert {:ok, journal_bytes} = File.read(journal_path)
    assert journal_bytes =~ "raw_event"
    assert journal_bytes =~ "sse-raw-frame-1"
    assert journal_bytes =~ "child-token"
  end

  defp sse_frame(json_rpc, opts) do
    [
      "event: ",
      Keyword.fetch!(opts, :event),
      "\n",
      "id: ",
      Keyword.fetch!(opts, :id),
      "\n",
      "data: ",
      Json.encode!(json_rpc),
      "\n\n"
    ]
  end
end
