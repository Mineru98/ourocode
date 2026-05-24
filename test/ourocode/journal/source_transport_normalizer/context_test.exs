defmodule Ourocode.Journal.SourceTransportNormalizer.ContextTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.SourceTransportNormalizer.Context

  test "from_options merges default context with atomized option context" do
    assert Context.from_options(
             context: %{
               "event_seq" => 10,
               "parent_call_id" => "parent-1",
               "runtime_source" => "runtime",
               "external_ids" => "invalid",
               "ignored" => "ignored"
             }
           ) == %{
             event_seq: 10,
             parent_call_id: "parent-1",
             runtime_source: "runtime",
             external_ids: %{}
           }
  end

  test "for_event applies next seq and overlays source event context" do
    default_context = Context.from_options(context: %{event_seq: 3, external_ids: %{}})

    assert Context.for_event(
             %{
               "context" => %{
                 "parent_call_id" => "event-parent",
                 "external_ids" => %{"session_id" => "session-1"},
                 "method" => "tools/call"
               }
             },
             default_context,
             12
           ) == %{
             event_seq: 12,
             parent_call_id: "event-parent",
             runtime_source: "source-transport-validation",
             external_ids: %{"session_id" => "session-1"},
             method: "tools/call"
           }
  end

  test "normalize handles non-map context with defaults" do
    assert Context.normalize(:invalid) == %{
             event_seq: 1,
             parent_call_id: "source-transport-validation",
             runtime_source: "source-transport-validation",
             external_ids: %{}
           }
  end
end
