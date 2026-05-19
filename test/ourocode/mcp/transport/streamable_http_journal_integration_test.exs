defmodule Ourocode.MCP.Transport.StreamableHTTPJournalIntegrationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.Json
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.StreamableHTTP
  alias Ourocode.MCP.Transport.StreamableHTTP.FrameNormalizer

  test "streamable HTTP raw request debug record includes transport correlation URL timestamp and payload reference" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => "call-http-raw-request-1",
      "method" => "tools/call",
      "params" => %{"name" => "synthetic.raw_request", "arguments" => %{"task" => "debug"}}
    }

    context = %{
      parent_call_id: "parent-http-raw-request-1",
      request_id: "call-http-raw-request-1",
      method: "tools/call",
      occurred_at_ms: 1_771_000_000_000
    }

    raw_payload = request |> Json.encode!() |> IO.iodata_to_binary()

    expected_payload_ref =
      "sha256:" <> Base.encode16(:crypto.hash(:sha256, raw_payload), case: :lower)

    assert %{
             transport: :streamable_http,
             transport_type: :streamable_http,
             stream_direction: :outbound,
             correlation_id: "call-http-raw-request-1",
             request_id: "call-http-raw-request-1",
             parent_call_id: "parent-http-raw-request-1",
             method: "tools/call",
             url: "http://127.0.0.1:9999/mcp",
             timestamp_ms: 1_771_000_000_000,
             sent_at_ms: 1_771_000_000_000,
             raw_payload_ref: ^expected_payload_ref,
             raw_payload_size_bytes: raw_payload_size_bytes
           } =
             StreamableHTTP.build_raw_request_event_record(
               [url: "http://127.0.0.1:9999/mcp"],
               request,
               context
             )

    assert raw_payload_size_bytes == byte_size(raw_payload)
  end

  test "streamable HTTP raw response debug record includes transport correlation status timestamp and payload reference" do
    raw_event = %{
      "jsonrpc" => "2.0",
      "id" => "call-http-raw-response-1",
      "result" => %{"ok" => true}
    }

    raw_payload = raw_event |> Json.encode!() |> IO.iodata_to_binary()

    context = %{
      parent_call_id: "parent-http-raw-response-1",
      request_id: "call-http-raw-response-1",
      occurred_at_ms: 1_771_000_001_000
    }

    expected_payload_ref =
      "sha256:" <> Base.encode16(:crypto.hash(:sha256, raw_payload), case: :lower)

    assert %{
             "jsonrpc" => "2.0",
             "id" => "call-http-raw-response-1",
             transport: :streamable_http,
             transport_type: :streamable_http,
             stream_direction: :inbound,
             correlation_id: "call-http-raw-response-1",
             request_id: "call-http-raw-response-1",
             parent_call_id: "parent-http-raw-response-1",
             status: 200,
             headers: [{"content-type", "application/json"}],
             timestamp_ms: 1_771_000_001_000,
             received_at_ms: 1_771_000_001_000,
             raw_payload_ref: ^expected_payload_ref,
             raw_payload_size_bytes: raw_payload_size_bytes
           } =
             StreamableHTTP.build_raw_response_event_record(
               [
                 status: 200,
                 headers: [{"content-type", "application/json"}],
                 raw_payload: raw_payload
               ],
               raw_event,
               context
             )

    assert raw_payload_size_bytes == byte_size(raw_payload)
  end

  test "streamable HTTP journal replay reconstructs canonical normalized events with raw metadata" do
    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-streamable-http-canonical-journal-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(journal_path) end)

    raw_frame =
      sse_frame(
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "childID" => "child-http-canonical-1",
            "seq" => 1,
            "token" => "canonical-http-token"
          }
        },
        event: "child-token",
        id: "http-raw-frame-1"
      )
      |> IO.iodata_to_binary()

    assert {:ok,
            [
              %LifecycleEvent{
                type: :parent_call_event,
                transport: :streamable_http,
                parent_call_id: "parent-http-canonical-1",
                raw_event: %{
                  "jsonrpc" => "2.0",
                  "method" => "notifications/progress",
                  "params" => %{
                    "childID" => "child-http-canonical-1",
                    "seq" => 1,
                    "token" => "canonical-http-token"
                  }
                }
              } = normalized_event
            ]} =
             FrameNormalizer.normalize_raw_frame(raw_frame, %{
               event_seq: 1,
               parent_call_id: "parent-http-canonical-1",
               runtime_source: "synthetic",
               external_ids: %{"session_id" => "session-http-canonical-1"},
               occurred_at_ms: 123,
               status: 200,
               headers: [{"content-type", "text/event-stream"}]
             })

    assert :ok =
             Journal.append(
               journal_path,
               StreamableHTTP.canonical_journal_event(normalized_event)
             )

    assert {:ok, [journaled_event]} = Journal.replay_normalized_events(journal_path)

    assert %{
             type: :parent_call_event,
             transport: :streamable_http,
             parent_call_id: "parent-http-canonical-1",
             runtime_source: "synthetic",
             notification: %{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{
                 "childID" => "child-http-canonical-1",
                 "seq" => 1,
                 "token" => "canonical-http-token"
               }
             }
           } = journaled_event

    assert journaled_event.raw_event == normalized_event.raw_event

    assert {:ok, journal_bytes} = File.read(journal_path)
    assert journal_bytes =~ "raw_event"
    assert journal_bytes =~ "http-raw-frame-1"
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
