defmodule Ourocode.Journal.SourceTransportNormalizer.RawMetadataTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.SourceTransportNormalizer.RawMetadata
  alias Ourocode.MCP.LifecycleEvent

  test "enrich merges known metadata into lifecycle raw_event without overwriting decoded fields" do
    event =
      LifecycleEvent.new(:child_session_started, %{
        event_seq: 1,
        transport: :stdio,
        parent_call_id: "parent-1",
        runtime_source: "runtime",
        external_ids: %{},
        occurred_at_ms: 10,
        raw_event: %{"method" => "notifications/progress", timestamp_ms: :decoded_wins}
      })

    [enriched] =
      RawMetadata.enrich(
        [event],
        %{
          transport: :stdio,
          metadata: %{
            "debug.trace_id" => "trace-1",
            timestamp_ms: 10_001,
            session_identifier: "session-1"
          }
        }
      )

    assert enriched.raw_event.timestamp_ms == :decoded_wins
    assert enriched.raw_event.session_identifier == "session-1"
    assert enriched.raw_event["debug.trace_id"] == "trace-1"
    assert enriched.raw_event["method"] == "notifications/progress"
  end

  test "enrich supports map events with string raw_event keys" do
    [enriched] =
      RawMetadata.enrich(
        [%{"raw_event" => %{"id" => "response-1"}}],
        %{
          "transport" => "streamable_http",
          "metadata" => %{
            "raw_payload_size_bytes" => 42,
            "debug.http.phase" => "body"
          }
        }
      )

    assert enriched["raw_event"].raw_payload_size_bytes == 42
    assert enriched["raw_event"]["debug.http.phase"] == "body"
    assert enriched["raw_event"]["id"] == "response-1"
  end

  test "source transport normalization handles known string transports" do
    assert RawMetadata.source_transport(%{"transport" => "stdio"}) == :stdio
    assert RawMetadata.source_transport(%{"transport" => "sse"}) == :sse
    assert RawMetadata.source_transport(%{"transport" => "streamable_http"}) == :streamable_http
    assert RawMetadata.source_transport(%{"transport" => :runtime}) == :runtime
    assert RawMetadata.source_transport(:not_a_map) == nil
  end
end
