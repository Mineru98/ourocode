defmodule Ourocode.Dashboard.UITreeTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPanes
  alias Ourocode.Dashboard.ParentMcpPane
  alias Ourocode.Dashboard.UITree

  test "replays persisted pane lifecycle events with stable pane identities" do
    tree =
      UITree.from_events([
        parent_started(:sse, "parent-tree-journal-1", 1),
        %{
          "type" => "child_pane_registered",
          "pane_id" => "child-pane:journald-tree-alpha",
          "child_id" => "runtime-tree-child-alpha",
          "parent_call_id" => "parent-tree-journal-1",
          "runtime_source" => "opencode",
          "transport" => "sse",
          "external_ids" => %{"session_id" => "runtime-tree-session-alpha"},
          "stream_cursor" => %{"event_id" => "journal-tree-event-1"},
          "pane_state" => %{
            "title" => "Recovered tree child",
            "last_event_seq" => 2,
            "stream_entries" => [%{"event_seq" => 2, "token" => "journal"}]
          },
          "created_at_ms" => "2",
          "updated_at_ms" => "2"
        },
        child_stream_event(
          :sse,
          "parent-tree-journal-1",
          "runtime-tree-child-alpha",
          3,
          2,
          "live"
        )
      ])

    assert %{
             roots: [
               %{
                 parent_call_id: "parent-tree-journal-1",
                 children: [
                   %{
                     id: "child-pane:journald-tree-alpha",
                     child_id: "runtime-tree-child-alpha",
                     parent_call_id: "parent-tree-journal-1",
                     stream_cursor: %{
                       transport: :sse,
                       child_id: "runtime-tree-child-alpha",
                       event_seq: 3
                     },
                     pane_state: %{
                       title: "Recovered tree child",
                       last_event_seq: 3
                     },
                     stream_events: [
                       %{event_seq: 2, token: "journal"},
                       %{event_seq: 3, token: "live"}
                     ]
                   }
                 ]
               }
             ],
             orphan_children: []
           } = tree
  end

  test "builds parent call to child session to stream event nodes from lifecycle events" do
    tree =
      UITree.from_events([
        parent_started(:streamable_http, "parent-tree-1", 1),
        child_stream_event(:streamable_http, "parent-tree-1", "child-tree-1", 2, 1, "first"),
        child_stream_event(:streamable_http, "parent-tree-1", "child-tree-1", 3, 2, "second")
      ])

    assert %{
             id: :ourocode_ui_tree,
             kind: :ui_tree,
             roots: [
               %{
                 id: "parent-mcp:parent-tree-1",
                 kind: :parent_call,
                 pane_kind: :parent_mcp_call,
                 status: :streaming,
                 parent_call_id: "parent-tree-1",
                 runtime_source: "synthetic",
                 transport: :streamable_http,
                 stream_cursor: %{
                   transport: :streamable_http,
                   parent_call_id: "parent-tree-1",
                   event_seq: 3
                 },
                 children: [
                   %{
                     id: "child-session:child-tree-1",
                     kind: :child_session,
                     status: :working,
                     child_id: "child-tree-1",
                     parent_call_id: "parent-tree-1",
                     transport: :streamable_http,
                     stream_cursor: %{
                       transport: :streamable_http,
                       child_id: "child-tree-1",
                       event_seq: 3
                     },
                     pane_state: %{
                       open?: true,
                       focused?: false,
                       renderer: :default_child_session,
                       last_event_seq: 3
                     },
                     stream_events: [
                       %{
                         id: "stream-event:child-tree-1:2:1",
                         kind: :stream_event,
                         child_id: "child-tree-1",
                         parent_call_id: "parent-tree-1",
                         event_seq: 2,
                         runtime_seq: 1,
                         type: :parent_call_event,
                         token: "first",
                         payload: %{"childID" => "child-tree-1", "seq" => 1, "token" => "first"}
                       },
                       %{
                         id: "stream-event:child-tree-1:3:2",
                         kind: :stream_event,
                         child_id: "child-tree-1",
                         parent_call_id: "parent-tree-1",
                         event_seq: 3,
                         runtime_seq: 2,
                         type: :parent_call_event,
                         token: "second",
                         payload: %{
                           "childID" => "child-tree-1",
                           "seq" => 2,
                           "token" => "second"
                         }
                       }
                     ]
                   }
                 ]
               }
             ],
             orphan_children: []
           } = tree
  end

  test "uses the same canonical node shape for stdio, streamable HTTP, and SSE input" do
    for transport <- [:stdio, :streamable_http, :sse] do
      parent_call_id = "parent-#{transport}"
      child_id = "child-#{transport}"

      tree =
        UITree.from_events([
          parent_started(transport, parent_call_id, 1),
          child_stream_event(transport, parent_call_id, child_id, 2, 1, "hello")
        ])

      assert [
               %{
                 kind: :parent_call,
                 parent_call_id: ^parent_call_id,
                 transport: ^transport,
                 children: [
                   %{
                     kind: :child_session,
                     child_id: ^child_id,
                     transport: ^transport,
                     stream_events: [
                       %{
                         kind: :stream_event,
                         parent_call_id: ^parent_call_id,
                         child_id: ^child_id,
                         event_seq: 2,
                         runtime_seq: 1,
                         token: "hello",
                         payload: %{
                           "childID" => ^child_id,
                           "seq" => 1,
                           "token" => "hello"
                         }
                       }
                     ]
                   }
                 ]
               }
             ] = tree.roots
    end
  end

  test "equivalent stdio, streamable HTTP, and SSE event sequences produce the same canonical UI tree model" do
    trees_by_transport =
      [:stdio, :streamable_http, :sse]
      |> Map.new(fn transport ->
        tree =
          transport
          |> equivalent_event_sequence()
          |> UITree.from_events()

        assert [
                 %{
                   transport: ^transport,
                   stream_cursor: %{transport: ^transport},
                   children: [
                     %{
                       transport: ^transport,
                       stream_cursor: %{transport: ^transport}
                     }
                   ]
                 }
               ] = tree.roots

        {transport, equivalent_tree_model(tree)}
      end)

    assert trees_by_transport.stdio == trees_by_transport.streamable_http
    assert trees_by_transport.stdio == trees_by_transport.sse

    assert %{
             id: :ourocode_ui_tree,
             kind: :ui_tree,
             roots: [
               %{
                 id: "parent-mcp:parent-equivalent-tree-1",
                 kind: :parent_call,
                 status: :completed,
                 parent_call_id: "parent-equivalent-tree-1",
                 runtime_source: "synthetic",
                 request_id: "call-equivalent-tree-1",
                 method: "tools/call",
                 stream_cursor: %{
                   parent_call_id: "parent-equivalent-tree-1",
                   event_seq: 4
                 },
                 children: [
                   %{
                     id: "child-session:child-equivalent-tree-1",
                     kind: :child_session,
                     status: :working,
                     child_id: "child-equivalent-tree-1",
                     parent_call_id: "parent-equivalent-tree-1",
                     runtime_source: "synthetic",
                     stream_cursor: %{
                       child_id: "child-equivalent-tree-1",
                       event_seq: 4
                     },
                     stream_events: [
                       %{
                         id: "stream-event:child-equivalent-tree-1:2:1",
                         kind: :stream_event,
                         parent_call_id: "parent-equivalent-tree-1",
                         child_id: "child-equivalent-tree-1",
                         event_seq: 2,
                         runtime_seq: 1,
                         type: :parent_call_event,
                         token: "alpha",
                         payload: %{
                           "childID" => "child-equivalent-tree-1",
                           "seq" => 1,
                           "token" => "alpha",
                           "cursor" => %{"offset" => 10}
                         }
                       },
                       %{
                         id: "stream-event:child-equivalent-tree-1:3:2",
                         kind: :stream_event,
                         parent_call_id: "parent-equivalent-tree-1",
                         child_id: "child-equivalent-tree-1",
                         event_seq: 3,
                         runtime_seq: 2,
                         type: :parent_call_event,
                         delta: " beta",
                         payload: %{
                           "childID" => "child-equivalent-tree-1",
                           "seq" => 2,
                           "delta" => " beta",
                           "cursor" => %{"offset" => 20}
                         }
                       },
                       %{
                         id: "stream-event:child-equivalent-tree-1:4:3",
                         kind: :stream_event,
                         parent_call_id: "parent-equivalent-tree-1",
                         child_id: "child-equivalent-tree-1",
                         event_seq: 4,
                         runtime_seq: 3,
                         type: :parent_call_result,
                         content: "done",
                         payload: %{
                           "childID" => "child-equivalent-tree-1",
                           "seq" => 3,
                           "content" => "done",
                           "ok" => true
                         }
                       }
                     ]
                   }
                 ]
               }
             ],
             orphan_children: []
           } = trees_by_transport.stdio
  end

  test "normalizes string-keyed SSE transport events into the canonical UI tree" do
    tree =
      UITree.from_events([
        %{
          "event_seq" => "1",
          "type" => "parent_call_started",
          "transport" => "sse",
          "parent_call_id" => "parent-sse-journal-1",
          "runtime_source" => "opencode",
          "external_ids" => %{"session_id" => "session-sse-journal-1"},
          "occurred_at_ms" => "100",
          "request_id" => "call-sse-journal-1",
          "method" => "tools/call",
          "params" => %{"name" => "ooo.run", "arguments" => %{"task" => "stream"}}
        },
        %{
          "event_seq" => "2",
          "type" => "parent_call_event",
          "transport" => "sse",
          "parent_call_id" => "parent-sse-journal-1",
          "runtime_source" => "opencode",
          "external_ids" => %{"session_id" => "session-sse-journal-1"},
          "occurred_at_ms" => "200",
          "raw_event" => %{
            "event" => "message",
            "id" => "sse-event-1",
            "data" => %{
              "jsonrpc" => "2.0",
              "method" => "notifications/progress",
              "params" => %{
                "childID" => "child-sse-journal-1",
                "seq" => "1",
                "token" => "alpha",
                "stream_cursor" => %{"event_id" => "sse-event-1", "offset" => 64}
              }
            }
          }
        },
        %{
          "event_seq" => "3",
          "type" => "parent_call_result",
          "transport" => "sse",
          "parent_call_id" => "parent-sse-journal-1",
          "runtime_source" => "opencode",
          "external_ids" => %{"session_id" => "session-sse-journal-1"},
          "occurred_at_ms" => "300",
          "request_id" => "call-sse-journal-1",
          "result" => %{
            "childID" => "child-sse-journal-1",
            "seq" => 2,
            "token" => "done",
            "ok" => true
          },
          "raw_event" => %{
            "event" => "message",
            "id" => "sse-event-2",
            "data" => %{
              "jsonrpc" => "2.0",
              "id" => "call-sse-journal-1",
              "result" => %{
                "childID" => "child-sse-journal-1",
                "seq" => 2,
                "token" => "done",
                "ok" => true
              }
            }
          }
        }
      ])

    assert %{
             id: :ourocode_ui_tree,
             kind: :ui_tree,
             roots: [
               %{
                 kind: :parent_call,
                 parent_call_id: "parent-sse-journal-1",
                 runtime_source: "opencode",
                 transport: :sse,
                 status: :completed,
                 stream_cursor: %{
                   transport: :sse,
                   parent_call_id: "parent-sse-journal-1",
                   event_seq: 3
                 },
                 children: [
                   %{
                     kind: :child_session,
                     child_id: "child-sse-journal-1",
                     parent_call_id: "parent-sse-journal-1",
                     runtime_source: "opencode",
                     transport: :sse,
                     stream_cursor: %{
                       transport: :sse,
                       child_id: "child-sse-journal-1",
                       event_seq: 3
                     },
                     stream_events: [
                       %{
                         kind: :stream_event,
                         event_seq: 2,
                         runtime_seq: 1,
                         token: "alpha",
                         payload: %{
                           "childID" => "child-sse-journal-1",
                           "seq" => "1",
                           "token" => "alpha",
                           "stream_cursor" => %{"event_id" => "sse-event-1", "offset" => 64}
                         }
                       },
                       %{
                         kind: :stream_event,
                         event_seq: 3,
                         runtime_seq: 2,
                         token: "done",
                         payload: %{
                           "childID" => "child-sse-journal-1",
                           "seq" => 2,
                           "token" => "done",
                           "ok" => true
                         }
                       }
                     ]
                   }
                 ]
               }
             ],
             orphan_children: []
           } = tree
  end

  test "builds the same canonical tree from pane projections" do
    events = [
      parent_started(:stdio, "parent-pane-tree-1", 1),
      child_stream_event(:stdio, "parent-pane-tree-1", "child-pane-tree-1", 2, 1, "pane")
    ]

    {parent_state, child_state} =
      Enum.reduce(
        events,
        {
          %{working: [], completed: [], focused: nil, open: []},
          %{working: [], completed: [], focused: nil, open: []}
        },
        fn event, {parents, children} ->
          {
            ParentMcpPane.apply_event(parents, event),
            ChildSessionPanes.apply_event(children, event)
          }
        end
      )

    assert UITree.from_panes(parent_state, child_state) == UITree.from_events(events)
  end

  test "projects multiple registered child panes under the same parent without overwriting siblings" do
    parent_state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ParentMcpPane.apply_event(parent_started(:sse, "parent-registered-siblings-1", 1))

    child_state =
      Enum.reduce(
        ["one", "two", "three"],
        %{working: [], completed: [], focused: nil, open: []},
        fn
          suffix, state ->
            assert {:ok, state} =
                     ChildSessionPanes.register_child_pane(state, %{
                       child_id: "child-registered-#{suffix}",
                       parent_call_id: "parent-registered-siblings-1",
                       runtime_source: "opencode",
                       transport: :sse,
                       external_ids: %{"thread_id" => "thread-registered-#{suffix}"},
                       stream_cursor: %{event_seq: String.length(suffix)},
                       pane_state: %{title: "Registered #{suffix}"},
                       created_at_ms: String.length(suffix) * 100,
                       updated_at_ms: String.length(suffix) * 100
                     })

            state
        end
      )

    tree = UITree.from_panes(parent_state, child_state)

    assert [
             %{
               parent_call_id: "parent-registered-siblings-1",
               children: children
             }
           ] = tree.roots

    assert Enum.map(children, & &1.id) == [
             "child-session:child-registered-one",
             "child-session:child-registered-two",
             "child-session:child-registered-three"
           ]

    assert Enum.map(children, & &1.child_id) == [
             "child-registered-one",
             "child-registered-two",
             "child-registered-three"
           ]

    assert Enum.map(children, & &1.parent_call_id) ==
             List.duplicate("parent-registered-siblings-1", 3)

    assert tree.orphan_children == []
  end

  test "keeps child session nodes without a matching parent as orphans" do
    tree =
      UITree.from_events([
        child_stream_event(:sse, "missing-parent-tree-1", "orphan-child-tree-1", 10, 1, "orphan")
      ])

    assert tree.roots == []

    assert [
             %{
               kind: :child_session,
               child_id: "orphan-child-tree-1",
               parent_call_id: "missing-parent-tree-1",
               stream_events: [
                 %{
                   kind: :stream_event,
                   child_id: "orphan-child-tree-1",
                   parent_call_id: "missing-parent-tree-1",
                   token: "orphan"
                 }
               ]
             }
           ] = tree.orphan_children
  end

  defp parent_started(transport, parent_call_id, event_seq) do
    %{
      event_seq: event_seq,
      type: :parent_call_started,
      transport: transport,
      parent_call_id: parent_call_id,
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-#{parent_call_id}"},
      occurred_at_ms: event_seq * 100,
      request_id: "call-#{parent_call_id}",
      method: "tools/call",
      params: %{"name" => "ooo.run", "arguments" => %{"task" => "inspect tree"}}
    }
  end

  defp child_stream_event(:sse, parent_call_id, child_id, event_seq, runtime_seq, token) do
    %{
      event_seq: event_seq,
      type: :parent_call_event,
      transport: :sse,
      parent_call_id: parent_call_id,
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-#{parent_call_id}"},
      occurred_at_ms: event_seq * 100,
      raw_event: %{
        "event" => "message",
        "data" => %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => stream_payload(child_id, runtime_seq, token)
        }
      }
    }
  end

  defp child_stream_event(transport, parent_call_id, child_id, event_seq, runtime_seq, token)
       when transport in [:stdio, :streamable_http] do
    %{
      event_seq: event_seq,
      type: :parent_call_event,
      transport: transport,
      parent_call_id: parent_call_id,
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-#{parent_call_id}"},
      occurred_at_ms: event_seq * 100,
      notification: %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => stream_payload(child_id, runtime_seq, token)
      }
    }
  end

  defp stream_payload(child_id, runtime_seq, token) do
    %{"childID" => child_id, "seq" => runtime_seq, "token" => token}
  end

  defp equivalent_event_sequence(transport) do
    parent_call_id = "parent-equivalent-tree-1"
    child_id = "child-equivalent-tree-1"

    [
      parent_started(transport, parent_call_id, 1)
      |> Map.put(:request_id, "call-equivalent-tree-1"),
      equivalent_stream_event(transport, parent_call_id, child_id, 2, %{
        "childID" => child_id,
        "seq" => 1,
        "token" => "alpha",
        "cursor" => %{"offset" => 10}
      }),
      equivalent_stream_event(transport, parent_call_id, child_id, 3, %{
        "childID" => child_id,
        "seq" => 2,
        "delta" => " beta",
        "cursor" => %{"offset" => 20}
      }),
      equivalent_result_event(transport, parent_call_id, child_id, 4, %{
        "childID" => child_id,
        "seq" => 3,
        "content" => "done",
        "ok" => true
      })
    ]
  end

  defp equivalent_stream_event(:sse, parent_call_id, _child_id, event_seq, payload) do
    %{
      event_seq: event_seq,
      type: :parent_call_event,
      transport: :sse,
      parent_call_id: parent_call_id,
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-#{parent_call_id}"},
      occurred_at_ms: event_seq * 100,
      raw_event: %{
        "event" => "message",
        "id" => "event-#{event_seq}",
        "data" => %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => payload
        }
      }
    }
  end

  defp equivalent_stream_event(transport, parent_call_id, _child_id, event_seq, payload)
       when transport in [:stdio, :streamable_http] do
    %{
      event_seq: event_seq,
      type: :parent_call_event,
      transport: transport,
      parent_call_id: parent_call_id,
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-#{parent_call_id}"},
      occurred_at_ms: event_seq * 100,
      notification: %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => payload
      }
    }
  end

  defp equivalent_result_event(:sse, parent_call_id, _child_id, event_seq, payload) do
    %{
      event_seq: event_seq,
      type: :parent_call_result,
      transport: :sse,
      parent_call_id: parent_call_id,
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-#{parent_call_id}"},
      occurred_at_ms: event_seq * 100,
      request_id: "call-equivalent-tree-1",
      result: payload,
      raw_event: %{
        "event" => "message",
        "id" => "event-#{event_seq}",
        "data" => %{
          "jsonrpc" => "2.0",
          "id" => "call-equivalent-tree-1",
          "result" => payload
        }
      }
    }
  end

  defp equivalent_result_event(transport, parent_call_id, _child_id, event_seq, payload)
       when transport in [:stdio, :streamable_http] do
    %{
      event_seq: event_seq,
      type: :parent_call_result,
      transport: transport,
      parent_call_id: parent_call_id,
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-#{parent_call_id}"},
      occurred_at_ms: event_seq * 100,
      request_id: "call-equivalent-tree-1",
      result: payload
    }
  end

  defp equivalent_tree_model(tree) do
    tree
    |> strip_transport()
    |> strip_timing()
    |> strip_empty_values()
  end

  defp strip_transport(%{} = map) do
    map
    |> Map.delete(:transport)
    |> Enum.map(fn {key, value} -> {key, strip_transport(value)} end)
    |> Map.new()
  end

  defp strip_transport(values) when is_list(values) do
    Enum.map(values, &strip_transport/1)
  end

  defp strip_transport(value), do: value

  defp strip_timing(%{} = map) do
    map
    |> Map.delete(:created_at_ms)
    |> Map.delete(:updated_at_ms)
    |> Map.delete(:occurred_at_ms)
    |> Enum.map(fn {key, value} -> {key, strip_timing(value)} end)
    |> Map.new()
  end

  defp strip_timing(values) when is_list(values) do
    Enum.map(values, &strip_timing/1)
  end

  defp strip_timing(value), do: value

  defp strip_empty_values(%{} = map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      value = strip_empty_values(value)

      if is_nil(value) or value == %{} do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp strip_empty_values(values) when is_list(values) do
    Enum.map(values, &strip_empty_values/1)
  end

  defp strip_empty_values(value), do: value
end
