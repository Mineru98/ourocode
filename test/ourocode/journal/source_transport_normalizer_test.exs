defmodule Ourocode.Journal.SourceTransportNormalizerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.Journal.SourceTransportNormalizer
  alias Ourocode.MCP.LifecycleEvent

  test "normalizes plugin runtime hook response events into first-class response lifecycle events" do
    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-hook-response-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(journal_path) end)

    result = %{
      "loaded" => true,
      "plugin_id" => "third-party-vim",
      "commands_registered" => ["/vim-mode"]
    }

    completion_metadata = %{
      "duration_ms" => 37,
      "completed_at_ms" => 73_002,
      "phase" => "plugin_command_registration"
    }

    assert {:ok, [%LifecycleEvent{} = event], %{transports: [:runtime]}} =
             SourceTransportNormalizer.normalize(
               [
                 %{
                   "type" => "hook_response",
                   "hook_id" => "hook-response-plugin-1",
                   "source" => "plugin_runtime",
                   "timestamp_ms" => 73_002,
                   "status" => "ok",
                   "result" => result,
                   "completion_metadata" => completion_metadata,
                   "payload" => %{
                     "summary" => "Plugin hook completed",
                     "result" => result,
                     "completion_metadata" => completion_metadata
                   }
                 }
               ],
               context: %{
                 event_seq: 43,
                 parent_call_id: "parent-hook-response-1",
                 runtime_source: "terminal-runtime",
                 external_ids: %{"session_id" => "session-hook-response-1"}
               }
             )

    assert event.type == :hook_response
    assert event.hook_id == "hook-response-plugin-1"
    assert event.source == :plugin_runtime
    assert event.transport == :runtime
    assert event.status == "ok"
    assert event.result == result
    assert event.error == nil
    assert event.completion_metadata == completion_metadata
    assert event.event_seq == 43
    assert event.occurred_at_ms == 73_002
    assert event.parent_call_id == "parent-hook-response-1"
    assert event.runtime_source == "plugin_runtime"
    assert event.external_ids == %{"session_id" => "session-hook-response-1"}
    assert event.raw_event["result"] == result

    assert :ok = Journal.append(journal_path, event)
    assert {:ok, [replayed]} = Journal.read_ordered(journal_path)
    assert replayed.type == :hook_response
    assert replayed.hook_id == "hook-response-plugin-1"
    assert replayed.source == :plugin_runtime
    assert replayed.transport == :runtime
    assert replayed.status == "ok"
    assert replayed.result == result
    assert replayed.error == nil
    assert replayed.completion_metadata == completion_metadata
  end

  test "normalizes runtime hook response errors with payload error and completion metadata" do
    error = %{"code" => "timeout", "message" => "Hook exceeded 5000ms"}

    assert {:ok, [%LifecycleEvent{} = event], %{transports: [:runtime]}} =
             SourceTransportNormalizer.normalize(
               [
                 %{
                   type: :runtime_hook_response,
                   hook_id: "hook-response-runtime-1",
                   source: :runtime,
                   occurred_at_ms: 74_002,
                   payload: %{
                     "status" => "error",
                     "error" => error,
                     "metadata" => %{
                       "duration_ms" => 5_001,
                       "timeout_ms" => 5_000,
                       "retryable" => true
                     }
                   }
                 }
               ],
               context: %{
                 event_seq: 44,
                 parent_call_id: "parent-hook-response-2",
                 runtime_source: "terminal-runtime",
                 external_ids: %{"session_id" => "session-hook-response-2"}
               }
             )

    assert event.type == :hook_response
    assert event.hook_id == "hook-response-runtime-1"
    assert event.source == :runtime
    assert event.transport == :runtime
    assert event.status == "error"
    assert event.result == nil
    assert event.error == error

    assert event.completion_metadata == %{
             "duration_ms" => 5_001,
             "timeout_ms" => 5_000,
             "retryable" => true
           }

    assert event.event_seq == 44
    assert event.occurred_at_ms == 74_002
    assert event.parent_call_id == "parent-hook-response-2"
    assert event.runtime_source == "runtime"
  end

  test "normalizes plugin runtime hook progress events into first-class lifecycle events" do
    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-hook-progress-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(journal_path) end)

    payload = %{
      "message" => "Loaded plugin manifest",
      "state" => "manifest_loaded",
      "ordering" => %{"phase_index" => 2, "phase_count" => 5},
      "plugin" => %{"id" => "third-party-vim", "origin" => "local"}
    }

    assert {:ok, [%LifecycleEvent{} = event], %{transports: [:runtime]}} =
             SourceTransportNormalizer.normalize(
               [
                 %{
                   type: :hook_progress,
                   hook_id: "hook-progress-1",
                   source: :plugin_runtime,
                   timestamp_ms: 72_001,
                   payload: payload
                 }
               ],
               context: %{
                 event_seq: 42,
                 parent_call_id: "parent-hook-progress-1",
                 runtime_source: "terminal-runtime",
                 external_ids: %{"session_id" => "session-hook-progress-1"}
               }
             )

    assert event.type == :hook_progress
    assert event.hook_id == "hook-progress-1"
    assert event.source == :plugin_runtime
    assert event.transport == :runtime
    assert event.progress_state == "manifest_loaded"
    assert event.ordering_metadata == %{"phase_index" => 2, "phase_count" => 5}
    assert event.event_seq == 42
    assert event.occurred_at_ms == 72_001
    assert event.parent_call_id == "parent-hook-progress-1"
    assert event.runtime_source == "plugin_runtime"
    assert event.payload == payload
    assert event.raw_event.payload == payload

    assert :ok = Journal.append(journal_path, event)
    assert {:ok, [replayed]} = Journal.read_ordered(journal_path)
    assert replayed.type == :hook_progress
    assert replayed.hook_id == "hook-progress-1"
    assert replayed.source == :plugin_runtime
    assert replayed.transport == :runtime
    assert replayed.progress_state == "manifest_loaded"
    assert replayed.ordering_metadata == %{"phase_index" => 2, "phase_count" => 5}
    assert replayed.payload == payload
  end

  test "normalizes plugin runtime hook started events into first-class lifecycle events" do
    payload = %{
      "hook" => "before_child_dispatch",
      "plugin_id" => "ouroboros-plugin",
      "args" => ["child-session-1"]
    }

    assert {:ok, [%LifecycleEvent{} = event], %{transports: [:runtime]}} =
             SourceTransportNormalizer.normalize(
               [
                 %{
                   "type" => "hook_started",
                   "hook_id" => "hook-started-1",
                   "source" => "plugin_runtime",
                   "timestamp_ms" => 71_001,
                   "payload" => payload
                 }
               ],
               context: %{
                 event_seq: 41,
                 parent_call_id: "parent-hook-started-1",
                 runtime_source: "terminal-runtime",
                 external_ids: %{"session_id" => "session-hook-started-1"}
               }
             )

    assert event.type == :hook_started
    assert event.hook_id == "hook-started-1"
    assert event.source == :plugin_runtime
    assert event.occurred_at_ms == 71_001
    assert event.payload == payload
    assert event.event_seq == 41
    assert event.parent_call_id == "parent-hook-started-1"
    assert event.runtime_source == "plugin_runtime"
    assert event.external_ids == %{"session_id" => "session-hook-started-1"}
    assert event.raw_event["payload"] == payload
  end

  test "preserves known stdio raw event metadata fields during source normalization" do
    decoded = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{"childID" => "child-stdio-metadata-1", "seq" => 1}
    }

    assert {:ok, [event], %{transports: [:stdio]}} =
             SourceTransportNormalizer.normalize([
               %{
                 transport: :stdio,
                 line: decoded |> Ourocode.Json.encode!() |> IO.iodata_to_binary(),
                 process_identifier: %{port: "#Port<0.1>", os_pid: 12_345},
                 session_identifier: "stdio-session-1",
                 stream_direction: :inbound,
                 timestamp_ms: 10_001,
                 raw_payload_ref: "sha256:stdio-payload"
               }
             ])

    assert event.raw_event.process_identifier == %{port: "#Port<0.1>", os_pid: 12_345}
    assert event.raw_event.session_identifier == "stdio-session-1"
    assert event.raw_event.stream_direction == :inbound
    assert event.raw_event.timestamp_ms == 10_001
    assert event.raw_event.raw_payload_ref == "sha256:stdio-payload"
    refute Map.has_key?(event.raw_event, :transport_type)
    assert event.raw_event["method"] == "notifications/progress"
  end

  test "preserves known SSE raw event metadata fields during source normalization" do
    parsed_event = %{
      "event" => "message",
      "id" => "sse-message-1",
      "data" => %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"childID" => "child-sse-metadata-1", "seq" => 2}
      }
    }

    assert {:ok, [event], %{transports: [:sse]}} =
             SourceTransportNormalizer.normalize([
               %{
                 transport: "sse",
                 event: parsed_event,
                 metadata: %{
                   "transport_type" => :sse,
                   "endpoint_url" => "http://localhost:4321/events",
                   "connection_identifier" => "conn-sse-1",
                   "session_identifier" => "sse-session-1",
                   "sse_event_id" => "sse-message-1",
                   "sse_event_id_present" => true,
                   "sse_event_type" => "message",
                   "sse_event_type_present" => true,
                   "timestamp_ms" => 20_001,
                   "received_at_ms" => 20_002,
                   "raw_payload_ref" => "sha256:sse-frame",
                   "raw_payload_stored?" => false,
                   "raw_payload_size_bytes" => 128
                 }
               }
             ])

    assert event.raw_event.transport_type == :sse
    assert event.raw_event.endpoint_url == "http://localhost:4321/events"
    assert event.raw_event.connection_identifier == "conn-sse-1"
    assert event.raw_event.session_identifier == "sse-session-1"
    assert event.raw_event.sse_event_id == "sse-message-1"
    assert event.raw_event.sse_event_id_present == true
    assert event.raw_event.sse_event_type == "message"
    assert event.raw_event.sse_event_type_present == true
    assert event.raw_event.timestamp_ms == 20_001
    assert event.raw_event.received_at_ms == 20_002
    assert event.raw_event.raw_payload_ref == "sha256:sse-frame"
    assert event.raw_event.raw_payload_stored? == false
    assert event.raw_event.raw_payload_size_bytes == 128
    assert event.raw_event["data"] == parsed_event["data"]
  end

  test "preserves known streamable HTTP raw event metadata fields during source normalization" do
    decoded = %{
      "jsonrpc" => "2.0",
      "id" => "http-response-1",
      "result" => %{"childID" => "child-http-metadata-1", "ok" => true}
    }

    assert {:ok, [event], %{transports: [:streamable_http]}} =
             SourceTransportNormalizer.normalize([
               %{
                 transport: :streamable_http,
                 status: 202,
                 headers: [{"content-type", "application/json"}],
                 body: decoded |> Ourocode.Json.encode!() |> IO.iodata_to_binary(),
                 metadata: %{
                   transport_type: :streamable_http,
                   stream_direction: :inbound,
                   correlation_id: "http-response-1",
                   request_id: "http-response-1",
                   parent_call_id: "parent-http-metadata-1",
                   method: "tools/call",
                   url: "http://localhost:4321/mcp",
                   timestamp_ms: 30_001,
                   received_at_ms: 30_002,
                   raw_payload_ref: "sha256:http-body",
                   raw_payload_size_bytes: 96
                 },
                 context: %{
                   parent_call_id: "parent-http-metadata-1",
                   runtime_source: "validation-test",
                   external_ids: %{},
                   event_seq: 7,
                   occurred_at_ms: 30_002
                 }
               }
             ])

    assert event.raw_event.transport_type == :streamable_http
    assert event.raw_event.stream_direction == :inbound
    assert event.raw_event.correlation_id == "http-response-1"
    assert event.raw_event.request_id == "http-response-1"
    assert event.raw_event.parent_call_id == "parent-http-metadata-1"
    assert event.raw_event.method == "tools/call"
    assert event.raw_event.status == 202
    assert event.raw_event.headers == [{"content-type", "application/json"}]
    assert event.raw_event.url == "http://localhost:4321/mcp"
    assert event.raw_event.timestamp_ms == 30_001
    assert event.raw_event.received_at_ms == 30_002
    assert event.raw_event.raw_payload_ref == "sha256:http-body"
    assert event.raw_event.raw_payload_size_bytes == 96
    assert event.raw_event["id"] == "http-response-1"
  end

  test "retains unknown debug metadata fields without filtering or renaming them" do
    stdio_decoded = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{"childID" => "child-debug-stdio", "seq" => 1}
    }

    sse_event = %{
      "data" => %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"childID" => "child-debug-sse", "seq" => 2}
      }
    }

    http_decoded = %{
      "jsonrpc" => "2.0",
      "id" => "http-debug-response",
      "result" => %{"childID" => "child-debug-http", "ok" => true}
    }

    assert {:ok, [stdio_event, sse_event, http_event],
            %{transports: [:sse, :stdio, :streamable_http]}} =
             SourceTransportNormalizer.normalize([
               %{
                 transport: :stdio,
                 line: stdio_decoded |> Ourocode.Json.encode!() |> IO.iodata_to_binary(),
                 metadata: %{
                   "debug.trace_id" => "trace-stdio-1",
                   {"debug", "tuple-key"} => "tuple-key-is-not-renamed",
                   "timestamp_ms" => 40_001,
                   debug_probe: %{sample: true}
                 }
               },
               %{
                 transport: :sse,
                 event: sse_event,
                 metadata: %{
                   "debug.raw_header" => "x-debug: sse",
                   "received_at_ms" => 40_002,
                   debug_context: %{"opaque" => ["left", "alone"]}
                 }
               },
               %{
                 transport: :streamable_http,
                 status: 200,
                 headers: [{"content-type", "application/json"}],
                 body: http_decoded |> Ourocode.Json.encode!() |> IO.iodata_to_binary(),
                 metadata: %{
                   "debug.http.phase" => "response-body",
                   :debug_atom_key => :kept_as_atom,
                   "raw_payload_size_bytes" => 48,
                   debug_bytes: <<1, 2, 3>>
                 }
               }
             ])

    assert stdio_event.raw_event["debug.trace_id"] == "trace-stdio-1"
    assert stdio_event.raw_event.debug_probe == %{sample: true}
    assert stdio_event.raw_event[{"debug", "tuple-key"}] == "tuple-key-is-not-renamed"
    assert stdio_event.raw_event.timestamp_ms == 40_001
    refute Map.has_key?(stdio_event.raw_event, "timestamp_ms")

    assert sse_event.raw_event["debug.raw_header"] == "x-debug: sse"
    assert sse_event.raw_event.debug_context == %{"opaque" => ["left", "alone"]}
    assert sse_event.raw_event.received_at_ms == 40_002
    refute Map.has_key?(sse_event.raw_event, "received_at_ms")

    assert http_event.raw_event["debug.http.phase"] == "response-body"
    assert http_event.raw_event.debug_bytes == <<1, 2, 3>>
    assert http_event.raw_event.debug_atom_key == :kept_as_atom
    assert http_event.raw_event.raw_payload_size_bytes == 48
    refute Map.has_key?(http_event.raw_event, "raw_payload_size_bytes")
  end
end
