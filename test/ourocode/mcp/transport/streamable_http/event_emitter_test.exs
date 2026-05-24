defmodule Ourocode.MCP.Transport.StreamableHTTP.EventEmitterTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.StreamableHTTP.EventEmitter

  test "emit delivers lifecycle events to pid subscribers" do
    event = event(:parent_call_started)

    assert :ok = EventEmitter.emit([subscriber: self()], event)

    assert_receive {:ourocode_event, ^event}
  end

  test "emit persists canonical lifecycle events to journal" do
    journal_path = tmp_journal_path!()
    event = event(:transport_decode_failed, error: {:invalid_json, "{"})

    assert :ok = EventEmitter.emit([journal_path: journal_path], event)

    assert {:ok, contents} = File.read(journal_path)
    assert contents =~ ~s("type":"transport_decode_failed")
    assert contents =~ ~s("transport":"streamable_http")
    assert contents =~ ~s("error":["invalid_json","{"])
  end

  test "canonical_journal_event delegates streamable HTTP raw event canonicalization" do
    canonical =
      EventEmitter.canonical_journal_event(event(:parent_call_result, result: %{ok: true}))

    assert canonical.type == :parent_call_result
    assert canonical.transport == :streamable_http
    assert canonical.result == %{ok: true}
  end

  defp event(type, attrs \\ []) do
    LifecycleEvent.new(
      type,
      Map.merge(
        %{
          event_seq: 1,
          transport: :streamable_http,
          parent_call_id: "parent-1",
          runtime_source: "test-runtime",
          external_ids: %{"session_id" => "session-1"},
          occurred_at_ms: 123
        },
        Map.new(attrs)
      )
    )
  end

  defp tmp_journal_path! do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-streamable-http-event-emitter-test-#{System.unique_integer([:positive])}.jsonl"
      )

    File.rm(path)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
