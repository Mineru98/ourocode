defmodule Ourocode.MCP.Transport.Stdio.EventEmitterTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.Stdio.EventEmitter

  test "emits lifecycle events to pid sinks and advances event sequence" do
    state = state(event_sink: self(), event_seq: 3)

    next_state =
      EventEmitter.emit(state, :parent_call_started, %{
        request_id: "request-1",
        external_ids: %{"session_id" => "child-session"}
      })

    assert next_state.event_seq == 4

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      event_seq: 4,
                      type: :parent_call_started,
                      transport: :stdio,
                      parent_call_id: "parent-1",
                      runtime_source: "test-runtime",
                      external_ids: %{"session_id" => "child-session"},
                      request_id: "request-1"
                    }}
  end

  test "emits lifecycle events to function sinks" do
    parent = self()
    sink = fn event -> send(parent, {:function_sink_event, event}) end

    assert %{event_seq: 1} = EventEmitter.emit(state(event_sink: sink), :transport_started, %{})

    assert_receive {:function_sink_event, %LifecycleEvent{type: :transport_started, event_seq: 1}}
  end

  test "persists canonical lifecycle events to journal" do
    journal_path = tmp_journal_path!()
    state = state(journal_path: journal_path, event_sink: nil)

    assert %{event_seq: 1} =
             EventEmitter.emit(state, :transport_decode_failed, %{
               error: {:malformed_stdout_line, {:invalid_json, "{"}},
               error_details: %{reason: {:invalid_json, "{"}}
             })

    assert {:ok, contents} = File.read(journal_path)
    assert contents =~ ~s("type":"transport_decode_failed")
    assert contents =~ ~s("transport":"stdio")
    assert contents =~ ~s("error":["malformed_stdout_line","invalid_json"])
  end

  test "emits normalized events without rebuilding them" do
    state = state(event_sink: self(), event_seq: 10)

    event =
      LifecycleEvent.new(:parent_call_failed, %{
        event_seq: 99,
        transport: :stdio,
        parent_call_id: "parent-normalized",
        runtime_source: "normalized-runtime",
        external_ids: %{},
        occurred_at_ms: 123,
        error: :timeout
      })

    assert %{event_seq: 99} = EventEmitter.emit_normalized(state, event)
    assert_receive {:ourocode_event, ^event}
  end

  test "builds next event context from transport state" do
    context = EventEmitter.context(state(event_seq: 41))

    assert %{
             event_seq: 42,
             parent_call_id: "parent-1",
             runtime_source: "test-runtime",
             external_ids: %{"session_id" => "session-1"}
           } = context

    assert is_integer(context.occurred_at_ms)
  end

  defp state(attrs) do
    defaults = %{
      event_seq: 0,
      event_sink: nil,
      journal_path: nil,
      parent_call_id: "parent-1",
      runtime_source: "test-runtime",
      external_ids: %{"session_id" => "session-1"}
    }

    Map.merge(defaults, Map.new(attrs))
  end

  defp tmp_journal_path! do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-stdio-event-emitter-test-#{System.unique_integer([:positive])}.jsonl"
      )

    File.rm(path)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
