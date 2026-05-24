defmodule Ourocode.MCP.Transport.StreamableHTTPTest do
  use ExUnit.Case, async: false

  alias Ourocode.Dashboard.ChildSessionPanes
  alias Ourocode.Dashboard.Layout
  alias Ourocode.Dashboard.ParentMcpPane
  alias Ourocode.Dashboard.UITree
  alias Ourocode.Config
  alias Ourocode.Journal
  alias Ourocode.Json
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.ParentCallResult
  alias Ourocode.MCP.Transport.StreamableHTTP

  test "executes a parent MCP call over streamable HTTP and emits the result" do
    {:ok, server} = start_fake_http_mcp_server()

    request = %{
      jsonrpc: "2.0",
      id: "call-1",
      method: "tools/call",
      params: %{name: "ooo.run", arguments: %{task: "ping"}}
    }

    assert {:ok, %ParentCallResult{} = result} =
             StreamableHTTP.execute_parent_call(
               [
                 url: "http://127.0.0.1:#{server.port}/mcp",
                 parent_call_id: "parent-call-1",
                 runtime_source: "synthetic",
                 external_ids: %{session_id: "session-1", call_id: "call-1"},
                 subscriber: self(),
                 timeout: 2_000
               ],
               request
             )

    assert result.parent_call_id == "parent-call-1"
    assert result.runtime_source == "synthetic"
    assert result.transport == :streamable_http
    assert result.external_ids == %{session_id: "session-1", call_id: "call-1"}
    assert result.status == 200
    assert result.response["jsonrpc"] == "2.0"
    assert result.response["id"] == "call-1"
    assert result.response["result"]["content"] == [%{"type" => "text", "text" => "pong"}]

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_started,
                      transport: :streamable_http,
                      parent_call_id: "parent-call-1",
                      runtime_source: "synthetic",
                      external_ids: %{session_id: "session-1", call_id: "call-1"},
                      request_id: "call-1",
                      method: "tools/call",
                      params: %{name: "ooo.run", arguments: %{task: "ping"}},
                      event_seq: 1,
                      raw_event: %{
                        transport: :streamable_http,
                        transport_type: :streamable_http,
                        stream_direction: :outbound,
                        correlation_id: "call-1",
                        request_id: "call-1",
                        parent_call_id: "parent-call-1",
                        method: "tools/call",
                        url: raw_request_url,
                        timestamp_ms: raw_request_timestamp_ms,
                        sent_at_ms: raw_request_sent_at_ms,
                        raw_payload_ref: raw_request_payload_ref,
                        raw_payload_size_bytes: raw_request_payload_size_bytes
                      }
                    }},
                   500

    assert raw_request_url == "http://127.0.0.1:#{server.port}/mcp"
    assert is_integer(raw_request_timestamp_ms)
    assert raw_request_sent_at_ms == raw_request_timestamp_ms
    assert String.starts_with?(raw_request_payload_ref, "sha256:")
    assert is_integer(raw_request_payload_size_bytes)
    assert raw_request_payload_size_bytes > 0

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      transport: :streamable_http,
                      parent_call_id: "parent-call-1",
                      runtime_source: "synthetic",
                      external_ids: %{session_id: "session-1", call_id: "call-1"},
                      request_id: "call-1",
                      result: %{"content" => [%{"type" => "text", "text" => "pong"}]},
                      event_seq: 2,
                      status: 200,
                      raw_event: %{
                        transport: :streamable_http,
                        transport_type: :streamable_http,
                        stream_direction: :inbound,
                        correlation_id: "call-1",
                        request_id: "call-1",
                        parent_call_id: "parent-call-1",
                        status: 200,
                        timestamp_ms: raw_response_timestamp_ms,
                        received_at_ms: raw_response_received_at_ms,
                        raw_payload_ref: raw_response_payload_ref,
                        raw_payload_size_bytes: raw_response_payload_size_bytes
                      }
                    }},
                   500

    assert is_integer(raw_response_timestamp_ms)
    assert raw_response_received_at_ms == raw_response_timestamp_ms
    assert String.starts_with?(raw_response_payload_ref, "sha256:")
    assert is_integer(raw_response_payload_size_bytes)
    assert raw_response_payload_size_bytes > 0

    assert_receive {:fake_server_request, raw_request}, 500
    assert raw_request =~ "POST /mcp HTTP/1.1"
    assert raw_request =~ "\"method\":\"tools/call\""
  end

  test "renders streamable HTTP token stream entries under the correct child session" do
    stream_events = [
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"childID" => "child-http-stream-1", "seq" => 1, "token" => "alpha"}
      },
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"childID" => "child-http-stream-2", "seq" => 1, "token" => "side"}
      },
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"childID" => "child-http-stream-1", "seq" => 2, "token" => "beta"}
      },
      %{
        "jsonrpc" => "2.0",
        "id" => "call-http-stream-1",
        "result" => %{
          "childID" => "child-http-stream-1",
          "seq" => 3,
          "token" => "done",
          "ok" => true
        }
      }
    ]

    {:ok, server} = start_fake_http_mcp_sse_server(stream_events)

    request = %{
      jsonrpc: "2.0",
      id: "call-http-stream-1",
      method: "tools/call",
      params: %{name: "ooo.run", arguments: %{task: "stream child tokens"}}
    }

    assert {:ok, %ParentCallResult{response: response}} =
             StreamableHTTP.execute_parent_call(
               [
                 url: "http://127.0.0.1:#{server.port}/mcp",
                 parent_call_id: "parent-http-stream-1",
                 runtime_source: "synthetic",
                 external_ids: %{
                   "session_id" => "session-http-stream-1",
                   "call_id" => "call-http-stream-1"
                 },
                 subscriber: self(),
                 timeout: 2_000
               ],
               request
             )

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => "call-http-stream-1",
             "result" => %{
               "childID" => "child-http-stream-1",
               "seq" => 3,
               "token" => "done",
               "ok" => true
             }
           }

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_started,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-stream-1",
                      request_id: "call-http-stream-1",
                      event_seq: 1
                    } = started},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      parent_call_id: "parent-http-stream-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-http-stream-1",
                          "seq" => 1,
                          "token" => "alpha"
                        }
                      },
                      event_seq: 2
                    } = first_token},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      parent_call_id: "parent-http-stream-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-http-stream-2",
                          "seq" => 1,
                          "token" => "side"
                        }
                      },
                      event_seq: 3
                    } = sibling_token},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      parent_call_id: "parent-http-stream-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-http-stream-1",
                          "seq" => 2,
                          "token" => "beta"
                        }
                      },
                      event_seq: 4
                    } = second_token},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      parent_call_id: "parent-http-stream-1",
                      result: %{
                        "childID" => "child-http-stream-1",
                        "seq" => 3,
                        "token" => "done",
                        "ok" => true
                      },
                      event_seq: 5
                    } = result},
                   500

    {parent_state, child_state} =
      Enum.reduce(
        [started, first_token, sibling_token, second_token, result],
        {
          %{working: [], completed: [], focused: nil, open: []},
          %{working: [], completed: [], focused: nil, open: []}
        },
        fn event, {parent_state, child_state} ->
          {
            ParentMcpPane.apply_event(parent_state, event),
            ChildSessionPanes.apply_event(child_state, event)
          }
        end
      )

    hierarchy = Layout.parent_child_hierarchy(parent_state, child_state)

    assert hierarchy.orphan_children == []

    assert [
             %{
               id: "parent-mcp:parent-http-stream-1",
               kind: :parent_mcp_call,
               status: "completed",
               parent_call_id: "parent-http-stream-1",
               transport: "streamable_http",
               children: [
                 %{
                   id: "child-session:child-http-stream-1",
                   kind: :child_session,
                   child_id: "child-http-stream-1",
                   parent_call_id: "parent-http-stream-1",
                   transport: "streamable_http",
                   pane_state: %{stream_entries: stream_entries}
                 },
                 %{
                   id: "child-session:child-http-stream-2",
                   kind: :child_session,
                   child_id: "child-http-stream-2",
                   parent_call_id: "parent-http-stream-1",
                   transport: "streamable_http",
                   pane_state: %{stream_entries: sibling_stream_entries}
                 }
               ]
             }
           ] = hierarchy.roots

    assert Enum.map(stream_entries, fn entry ->
             Map.take(entry, [:event_seq, :runtime_seq, :token, :type])
           end) == [
             %{event_seq: 2, runtime_seq: 1, token: "alpha", type: :parent_call_event},
             %{event_seq: 4, runtime_seq: 2, token: "beta", type: :parent_call_event},
             %{event_seq: 5, runtime_seq: 3, token: "done", type: :parent_call_result}
           ]

    assert Enum.map(sibling_stream_entries, fn entry ->
             Map.take(entry, [:event_seq, :runtime_seq, :token, :type])
           end) == [
             %{event_seq: 3, runtime_seq: 1, token: "side", type: :parent_call_event}
           ]

    assert_receive {:fake_server_request, raw_request}, 500
    assert raw_request =~ "POST /mcp HTTP/1.1"
    assert raw_request =~ "\"task\":\"stream child tokens\""
  end

  test "default cleanup clears streamable HTTP parent and child live pane state within configured timeout" do
    child_id = "child-http-pane-cleanup-1"
    parent_call_id = "parent-http-pane-cleanup-1"
    call_id = "call-http-pane-cleanup-1"
    session_id = "session-http-pane-cleanup-1"
    cleanup_policy = Config.default_cleanup_policy()

    stream_events = [
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"childID" => child_id, "seq" => 1, "token" => "alpha"}
      },
      %{
        "jsonrpc" => "2.0",
        "id" => call_id,
        "result" => %{"childID" => child_id, "seq" => 2, "token" => "done", "ok" => true}
      }
    ]

    {:ok, server} = start_fake_http_mcp_sse_server(stream_events)

    request = %{
      jsonrpc: "2.0",
      id: call_id,
      method: "tools/call",
      params: %{name: "ooo.run", arguments: %{task: "cleanup streamable HTTP panes"}}
    }

    assert {:ok, %ParentCallResult{}} =
             StreamableHTTP.execute_parent_call(
               [
                 url: "http://127.0.0.1:#{server.port}/mcp",
                 parent_call_id: parent_call_id,
                 runtime_source: "synthetic",
                 external_ids: %{"session_id" => session_id, "call_id" => call_id},
                 subscriber: self(),
                 timeout: 2_000
               ],
               request
             )

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_started,
                      parent_call_id: ^parent_call_id,
                      transport: :streamable_http,
                      event_seq: 1
                    } = started},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      parent_call_id: ^parent_call_id,
                      transport: :streamable_http,
                      event_seq: 2
                    } = first_token},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      parent_call_id: ^parent_call_id,
                      transport: :streamable_http,
                      event_seq: 3
                    } = result},
                   500

    {parent_state, child_state} =
      Enum.reduce(
        [started, first_token, result],
        {
          %{working: [], completed: [], focused: nil, open: []},
          ChildSessionPanes.new()
        },
        fn event, {parent_state, child_state} ->
          {
            ParentMcpPane.apply_event(parent_state, event),
            ChildSessionPanes.apply_event(child_state, event)
          }
        end
      )

    assert %{
             working: [],
             completed: [%{parent_call_id: ^parent_call_id}],
             focused: parent_pane_id
           } =
             parent_state

    assert parent_pane_id == "parent-mcp:#{parent_call_id}"

    assert %{
             working: [
               %{
                 id: child_pane_id,
                 child_id: ^child_id,
                 parent_call_id: ^parent_call_id,
                 transport: :streamable_http,
                 pane_state: %{stream_entries: stream_entries}
               }
             ],
             completed: [],
             focused: focused_child_pane_id,
             open: open_child_pane_ids,
             child_pane_registry: child_pane_registry
           } = child_state

    assert focused_child_pane_id == child_pane_id
    assert open_child_pane_ids == [child_pane_id]
    assert child_pane_registry == %{child_id => child_pane_id}

    assert Enum.map(stream_entries, & &1.runtime_seq) == [1, 2]

    cleanup_event = %{
      type: :stream_cleanup,
      stream_kind: :child,
      cleanup_reason: :idle_timeout,
      parent_call_id: parent_call_id,
      child_id: child_id,
      session_id: session_id,
      runtime_source: "synthetic",
      transport: :streamable_http,
      external_ids: %{"session_id" => session_id, "childID" => child_id},
      stale_cleanup_timeout_ms: cleanup_policy.stale_cleanup_timeout_ms,
      stream_subscription_cleanup_timeout_ms:
        cleanup_policy.stream_subscription_cleanup_timeout_ms,
      pane_state_retention_ms: cleanup_policy.pane_state_retention_ms
    }

    cleanup_started_at = System.monotonic_time(:millisecond)

    cleaned_parent_state = ParentMcpPane.apply_event(parent_state, cleanup_event)
    cleaned_child_state = ChildSessionPanes.apply_event(child_state, cleanup_event)

    cleanup_elapsed_ms = System.monotonic_time(:millisecond) - cleanup_started_at

    assert cleanup_elapsed_ms <= cleanup_policy.stale_cleanup_timeout_ms
    assert cleanup_event.stale_cleanup_timeout_ms == Config.default_stale_cleanup_timeout_ms()

    assert cleanup_event.stream_subscription_cleanup_timeout_ms ==
             Config.default_stream_subscription_cleanup_timeout_ms()

    assert cleanup_event.pane_state_retention_ms == Config.default_pane_state_retention_ms()

    assert %{working: [], completed: [], focused: nil, open: []} = cleaned_parent_state

    assert %{
             working: [],
             completed: [],
             focused: nil,
             open: [],
             child_pane_registry: %{}
           } = cleaned_child_state

    assert ParentMcpPane.render(cleaned_parent_state).empty?
    assert ChildSessionPanes.render(cleaned_child_state).empty?
    assert Layout.parent_child_hierarchy(cleaned_parent_state, cleaned_child_state).roots == []

    assert_receive {:fake_server_request, raw_request}, 500
    assert raw_request =~ "\"task\":\"cleanup streamable HTTP panes\""
  end

  test "live pane adapter renders decoded streamable HTTP synthetic MCP events seq=1..N with no gaps" do
    event_count = 12
    child_id = "child-seq-http-1"
    result_seq = event_count + 1

    stream_events =
      Enum.map(1..event_count, fn seq ->
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "childID" => child_id,
            "seq" => seq,
            "token" => "token-#{seq}"
          }
        }
      end) ++
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "call-http-seq-1",
            "result" => %{
              "ok" => true,
              "childID" => child_id,
              "seq" => result_seq
            }
          }
        ]

    {:ok, server} = start_fake_http_mcp_sse_server(stream_events, body_chunk_size: 11)

    request = %{
      jsonrpc: "2.0",
      id: "call-http-seq-1",
      method: "tools/call",
      params: %{name: "synthetic.seq", arguments: %{task: "verify streamable HTTP seq integrity"}}
    }

    assert {:ok, %ParentCallResult{response: response}} =
             StreamableHTTP.execute_parent_call(
               [
                 url: "http://127.0.0.1:#{server.port}/mcp",
                 parent_call_id: "parent-http-seq-1",
                 runtime_source: "synthetic",
                 external_ids: %{"session_id" => "session-http-seq-1"},
                 subscriber: self(),
                 timeout: 2_000
               ],
               request
             )

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => "call-http-seq-1",
             "result" => %{
               "ok" => true,
               "childID" => child_id,
               "seq" => result_seq
             }
           }

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_started,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-seq-1",
                      runtime_source: "synthetic",
                      request_id: "call-http-seq-1",
                      event_seq: 1
                    } = started_event},
                   500

    stream_lifecycle_events =
      Enum.map(1..event_count, fn seq ->
        assert_receive {:ourocode_event,
                        %LifecycleEvent{
                          type: :parent_call_event,
                          transport: :streamable_http,
                          parent_call_id: "parent-http-seq-1",
                          notification: %{
                            "method" => "notifications/progress",
                            "params" => %{
                              "childID" => ^child_id,
                              "seq" => ^seq,
                              "token" => token
                            }
                          },
                          raw_event: %{
                            "params" => %{
                              "childID" => ^child_id,
                              "seq" => ^seq
                            }
                          },
                          event_seq: event_seq
                        } = event},
                       500

        assert token == "token-#{seq}"
        assert event_seq == seq + 1
        event
      end)

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-seq-1",
                      result: %{
                        "ok" => true,
                        "childID" => ^child_id,
                        "seq" => ^result_seq
                      },
                      event_seq: result_event_seq
                    } = result_event},
                   500

    assert result_event_seq == event_count + 2
    refute_receive {:ourocode_event, %LifecycleEvent{type: :parent_call_event}}, 50

    assert Enum.map(stream_lifecycle_events, &get_in(&1.notification, ["params", "seq"])) ==
             Enum.to_list(1..event_count)

    assert stream_lifecycle_events
           |> Enum.map(&get_in(&1.notification, ["params", "seq"]))
           |> Enum.uniq() == Enum.to_list(1..event_count)

    assert Enum.map(stream_lifecycle_events, & &1.event_seq) == Enum.to_list(2..(event_count + 1))
    all_events = [started_event] ++ stream_lifecycle_events ++ [result_event]
    assert :ok = Journal.verify_no_event_seq_gaps(all_events)

    child_state =
      Enum.reduce(stream_lifecycle_events, ChildSessionPanes.new(), fn event, state ->
        ChildSessionPanes.apply_event(state, event)
      end)

    assert [
             %{
               child_id: ^child_id,
               parent_call_id: "parent-http-seq-1",
               transport: :streamable_http,
               stream_cursor: %{event_seq: last_stream_event_seq},
               pane_state: %{stream_entries: stream_entries}
             }
           ] = child_state.working

    assert last_stream_event_seq == event_count + 1
    assert Enum.map(stream_entries, & &1.runtime_seq) == Enum.to_list(1..event_count)
    assert Enum.map(stream_entries, & &1.token) == Enum.map(1..event_count, &"token-#{&1}")

    rendered_children = ChildSessionPanes.render(child_state)

    assert [
             %{
               child_id: ^child_id,
               transport: "streamable_http",
               stream_event_count: ^event_count,
               pane_state: %{stream_entries: rendered_stream_entries},
               line: rendered_line
             }
           ] = rendered_children.working

    assert Enum.map(rendered_stream_entries, & &1.runtime_seq) == Enum.to_list(1..event_count)

    assert Enum.map(rendered_stream_entries, & &1.token) ==
             Enum.map(1..event_count, &"token-#{&1}")

    assert rendered_line =~ "transport=streamable_http"
    assert rendered_line =~ "events=#{event_count}"

    parent_state =
      [started_event | stream_lifecycle_events]
      |> Enum.reduce(%{working: [], completed: [], focused: nil, open: []}, fn event, state ->
        ParentMcpPane.apply_event(state, event)
      end)

    frame = Layout.render_runtime_frame(parent_state, child_state)

    rendered_runtime_seqs =
      ~r/(?:stream=\[|\|)(\d+):token=token-\d+/
      |> Regex.scan(frame, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)

    assert rendered_runtime_seqs == Enum.to_list(1..event_count)

    tree = UITree.from_panes(parent_state, child_state)

    assert [
             %{
               children: [
                 %{
                   child_id: ^child_id,
                   transport: :streamable_http,
                   stream_events: rendered_stream_events
                 }
               ]
             }
           ] = tree.roots

    assert Enum.map(rendered_stream_events, & &1.runtime_seq) == Enum.to_list(1..event_count)

    assert Enum.map(rendered_stream_events, & &1.token) ==
             Enum.map(1..event_count, &"token-#{&1}")

    assert_receive {:fake_server_request, raw_request}, 500
    assert raw_request =~ "POST /mcp HTTP/1.1"
    assert raw_request =~ "\"task\":\"verify streamable HTTP seq integrity\""
  end

  test "persists decoded streamable HTTP synthetic MCP server events seq=1..N without journal gaps" do
    event_count = 9
    child_id = "child-journal-http-1"
    result_seq = event_count + 1

    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-streamable-http-journal-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(journal_path) end)

    stream_events =
      Enum.map(1..event_count, fn seq ->
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "childID" => child_id,
            "seq" => seq,
            "token" => "journal-http-token-#{seq}"
          }
        }
      end) ++
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "call-http-journal-1",
            "result" => %{
              "ok" => true,
              "childID" => child_id,
              "seq" => result_seq
            }
          }
        ]

    {:ok, server} = start_fake_http_mcp_sse_server(stream_events, body_chunk_size: 7)

    request = %{
      jsonrpc: "2.0",
      id: "call-http-journal-1",
      method: "tools/call",
      params: %{name: "synthetic.journal", arguments: %{task: "persist HTTP seq stream"}}
    }

    assert {:ok, %ParentCallResult{response: response}} =
             StreamableHTTP.execute_parent_call(
               [
                 url: "http://127.0.0.1:#{server.port}/mcp",
                 parent_call_id: "parent-http-journal-1",
                 runtime_source: "synthetic",
                 external_ids: %{"session_id" => "session-http-journal-1"},
                 subscriber: self(),
                 journal_path: journal_path,
                 timeout: 2_000
               ],
               request
             )

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => "call-http-journal-1",
             "result" => %{
               "ok" => true,
               "childID" => child_id,
               "seq" => result_seq
             }
           }

    received_events =
      Enum.map(1..(event_count + 2), fn expected_seq ->
        assert_receive {:ourocode_event, %LifecycleEvent{event_seq: ^expected_seq} = event}, 500
        event
      end)

    assert :ok = Journal.verify_no_event_seq_gaps(received_events)
    assert {:ok, journal_entries} = Journal.read_ordered(journal_path)
    assert Enum.map(journal_entries, & &1.event_seq) == Enum.to_list(1..(event_count + 2))

    assert Enum.map(journal_entries, & &1.type) ==
             [
               :parent_call_started
             ] ++ List.duplicate(:parent_call_event, event_count) ++ [:parent_call_result]

    stream_entries = Enum.filter(journal_entries, &(&1.type == :parent_call_event))

    assert Enum.map(stream_entries, &get_in(&1, [:notification, "params", "seq"])) ==
             Enum.to_list(1..event_count)

    assert Enum.map(stream_entries, &get_in(&1, [:notification, "params", "token"])) ==
             Enum.map(1..event_count, &"journal-http-token-#{&1}")

    assert [
             %{
               type: :parent_call_result,
               transport: :streamable_http,
               parent_call_id: "parent-http-journal-1",
               result: %{"ok" => true, "childID" => ^child_id, "seq" => ^result_seq}
             }
           ] = Enum.filter(journal_entries, &(&1.type == :parent_call_result))

    assert_receive {:fake_server_request, raw_request}, 500
    assert raw_request =~ "POST /mcp HTTP/1.1"
    assert raw_request =~ "\"task\":\"persist HTTP seq stream\""
  end

  test "emits a streamable HTTP childID creation event observed by pane routing" do
    stream_events = [
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{
          "childID" => "child-http-created-1",
          "phase" => "created"
        }
      },
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{
          "childID" => "child-http-created-1",
          "seq" => 1,
          "token" => "first-token"
        }
      },
      %{
        "jsonrpc" => "2.0",
        "id" => "call-http-created-1",
        "result" => %{
          "childID" => "child-http-created-1",
          "seq" => 1,
          "ok" => true
        }
      }
    ]

    {:ok, server} = start_fake_http_mcp_sse_server(stream_events)

    request = %{
      jsonrpc: "2.0",
      id: "call-http-created-1",
      method: "tools/call",
      params: %{name: "ooo.run", arguments: %{task: "route created child pane"}}
    }

    assert {:ok, %ParentCallResult{response: response}} =
             StreamableHTTP.execute_parent_call(
               [
                 url: "http://127.0.0.1:#{server.port}/mcp",
                 parent_call_id: "parent-http-created-1",
                 runtime_source: "synthetic",
                 external_ids: %{
                   "session_id" => "session-http-created-1",
                   "call_id" => "call-http-created-1"
                 },
                 subscriber: self(),
                 timeout: 2_000
               ],
               request
             )

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => "call-http-created-1",
             "result" => %{"childID" => "child-http-created-1", "seq" => 1, "ok" => true}
           }

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_started,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-created-1",
                      request_id: "call-http-created-1",
                      event_seq: 1
                    } = started},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-created-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-http-created-1",
                          "phase" => "created"
                        }
                      },
                      event_seq: 2
                    } = child_created},
                   500

    child_state =
      ChildSessionPanes.apply_event(
        %{working: [], completed: [], focused: nil, open: []},
        child_created
      )

    assert [
             %{
               id: "child-session:child-http-created-1",
               child_id: "child-http-created-1",
               parent_call_id: "parent-http-created-1",
               runtime_source: "synthetic",
               transport: :streamable_http,
               external_ids: %{
                 "session_id" => "session-http-created-1",
                 "call_id" => "call-http-created-1",
                 "childID" => "child-http-created-1"
               },
               stream_cursor: %{
                 transport: :streamable_http,
                 event_seq: 2,
                 child_id: "child-http-created-1"
               },
               pane_state: %{stream_entries: []}
             }
           ] = child_state.working

    assert child_state.focused == "child-session:child-http-created-1"
    assert child_state.open == ["child-session:child-http-created-1"]

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-created-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-http-created-1",
                          "seq" => 1,
                          "token" => "first-token"
                        }
                      },
                      event_seq: 3
                    } = first_token},
                   500

    child_state = ChildSessionPanes.apply_event(child_state, first_token)

    assert [
             %{
               id: "child-session:child-http-created-1",
               pane_state: %{
                 stream_entries: [
                   %{
                     event_seq: 3,
                     runtime_seq: 1,
                     token: "first-token",
                     payload: %{
                       "childID" => "child-http-created-1",
                       "seq" => 1,
                       "token" => "first-token"
                     }
                   }
                 ]
               }
             }
           ] = child_state.working

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-created-1",
                      result: %{"childID" => "child-http-created-1", "seq" => 1, "ok" => true},
                      event_seq: 4
                    }},
                   500

    routed_tree = UITree.from_events([started, child_created, first_token])

    assert [
             %{
               id: "parent-mcp:parent-http-created-1",
               children: [
                 %{
                   id: "child-session:child-http-created-1",
                   child_id: "child-http-created-1",
                   stream_events: [
                     %{
                       event_seq: 3,
                       runtime_seq: 1,
                       token: "first-token"
                     }
                   ]
                 }
               ]
             }
           ] = routed_tree.roots

    assert_receive {:fake_server_request, raw_request}, 500
    assert raw_request =~ "POST /mcp HTTP/1.1"
    assert raw_request =~ "\"task\":\"route created child pane\""
  end

  test "delivers the first streamable HTTP token within five seconds after childID creation" do
    child_created =
      sse_frame(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{
          "childID" => "child-http-timing-1",
          "phase" => "created"
        }
      })

    first_token =
      sse_frame(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{
          "childID" => "child-http-timing-1",
          "seq" => 1,
          "token" => "first-timing-token"
        }
      })

    final_result =
      sse_frame(%{
        "jsonrpc" => "2.0",
        "id" => "call-http-timing-1",
        "result" => %{
          "childID" => "child-http-timing-1",
          "seq" => 2,
          "ok" => true
        }
      })

    {:ok, server} =
      start_fake_http_mcp_streaming_sse_server([
        {:send, child_created},
        {:sleep, 50},
        {:send, first_token},
        {:send, final_result}
      ])

    request = %{
      jsonrpc: "2.0",
      id: "call-http-timing-1",
      method: "tools/call",
      params: %{name: "ooo.run", arguments: %{task: "prove streamable HTTP timing"}}
    }

    parent = self()

    task =
      Task.async(fn ->
        StreamableHTTP.execute_parent_call(
          [
            url: "http://127.0.0.1:#{server.port}/mcp",
            parent_call_id: "parent-http-timing-1",
            runtime_source: "synthetic",
            external_ids: %{
              "session_id" => "session-http-timing-1",
              "call_id" => "call-http-timing-1"
            },
            subscriber: parent,
            timeout: 2_000
          ],
          request
        )
      end)

    assert_receive {:fake_server_request, raw_request}, 500
    assert raw_request =~ "POST /mcp HTTP/1.1"
    assert raw_request =~ "\"task\":\"prove streamable HTTP timing\""

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_started,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-timing-1",
                      request_id: "call-http-timing-1",
                      event_seq: 1
                    }},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-timing-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-http-timing-1",
                          "phase" => "created"
                        }
                      },
                      event_seq: 2
                    } = child_created_event},
                   500

    child_created_at = System.monotonic_time(:millisecond)

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-timing-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-http-timing-1",
                          "seq" => 1,
                          "token" => "first-timing-token"
                        }
                      },
                      event_seq: 3
                    } = first_token_event},
                   5_000

    first_token_at = System.monotonic_time(:millisecond)
    assert first_token_at - child_created_at <= 5_000

    child_state =
      ChildSessionPanes.new()
      |> ChildSessionPanes.apply_event(child_created_event)
      |> ChildSessionPanes.apply_event(first_token_event)

    assert [
             %{
               id: "child-session:child-http-timing-1",
               child_id: "child-http-timing-1",
               pane_state: %{
                 stream_entries: [
                   %{
                     event_seq: 3,
                     runtime_seq: 1,
                     token: "first-timing-token"
                   }
                 ]
               }
             }
           ] = child_state.working

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-timing-1",
                      result: %{
                        "childID" => "child-http-timing-1",
                        "seq" => 2,
                        "ok" => true
                      },
                      event_seq: 4
                    }},
                   500

    assert {:ok,
            %ParentCallResult{
              response: %{
                "jsonrpc" => "2.0",
                "id" => "call-http-timing-1",
                "result" => %{
                  "childID" => "child-http-timing-1",
                  "seq" => 2,
                  "ok" => true
                }
              }
            }} = Task.await(task, 1_000)
  end

  test "returns as soon as an SSE JSON-RPC response arrives even if the stream stays open" do
    final_result =
      sse_frame(%{
        "jsonrpc" => "2.0",
        "id" => "call-http-open-1",
        "result" => %{"ok" => true}
      })

    {:ok, server} =
      start_fake_http_mcp_streaming_sse_server([
        {:send, final_result},
        {:sleep, 1_000}
      ])

    request = %{
      jsonrpc: "2.0",
      id: "call-http-open-1",
      method: "tools/call",
      params: %{name: "ooo.interview", arguments: %{task: "return before stream close"}}
    }

    task =
      Task.async(fn ->
        StreamableHTTP.execute_parent_call(
          [
            url: "http://127.0.0.1:#{server.port}/mcp",
            parent_call_id: "parent-http-open-1",
            runtime_source: "synthetic",
            subscriber: self(),
            timeout: 2_000
          ],
          request
        )
      end)

    assert {:ok,
            %ParentCallResult{
              response: %{
                "jsonrpc" => "2.0",
                "id" => "call-http-open-1",
                "result" => %{"ok" => true}
              }
            }} = Task.await(task, 500)
  end

  test "routes the first streamable HTTP token for an existing childID to its child pane" do
    stream_events = [
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{
          "childID" => "child-http-existing-1",
          "seq" => 1,
          "token" => "first-existing-token",
          "cursor" => %{"offset" => 1}
        }
      },
      %{
        "jsonrpc" => "2.0",
        "id" => "call-http-existing-1",
        "result" => %{
          "childID" => "child-http-existing-1",
          "seq" => 2,
          "token" => "done",
          "ok" => true
        }
      }
    ]

    {:ok, server} = start_fake_http_mcp_sse_server(stream_events)

    request = %{
      jsonrpc: "2.0",
      id: "call-http-existing-1",
      method: "tools/call",
      params: %{name: "ooo.run", arguments: %{task: "route existing child token"}}
    }

    existing_child_state =
      ChildSessionPanes.new()
      |> ChildSessionPanes.apply_event(%{
        type: :child_pane_registered,
        pane_id: "child-pane:stable-existing-http",
        child_id: "child-http-existing-1",
        parent_call_id: "parent-http-existing-1",
        runtime_source: "synthetic",
        transport: :streamable_http,
        external_ids: %{
          "session_id" => "session-http-existing-1",
          "call_id" => "call-http-existing-1"
        },
        pane_state: %{title: "Existing HTTP child", stream_entries: []},
        created_at_ms: 10,
        updated_at_ms: 10
      })

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %ParentCallResult{response: response}} =
             StreamableHTTP.execute_parent_call(
               [
                 url: "http://127.0.0.1:#{server.port}/mcp",
                 parent_call_id: "parent-http-existing-1",
                 runtime_source: "synthetic",
                 external_ids: %{
                   "session_id" => "session-http-existing-1",
                   "call_id" => "call-http-existing-1"
                 },
                 subscriber: self(),
                 timeout: 2_000
               ],
               request
             )

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => "call-http-existing-1",
             "result" => %{
               "childID" => "child-http-existing-1",
               "seq" => 2,
               "token" => "done",
               "ok" => true
             }
           }

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_started,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-existing-1",
                      request_id: "call-http-existing-1",
                      event_seq: 1
                    }},
                   500

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_event,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-existing-1",
                      notification: %{
                        "params" => %{
                          "childID" => "child-http-existing-1",
                          "seq" => 1,
                          "token" => "first-existing-token",
                          "cursor" => %{"offset" => 1}
                        }
                      },
                      event_seq: 2
                    } = first_token},
                   5_000

    assert System.monotonic_time(:millisecond) - started_at <= 5_000

    routed_child_state = ChildSessionPanes.apply_event(existing_child_state, first_token)

    assert [
             %{
               id: "child-pane:stable-existing-http",
               child_id: "child-http-existing-1",
               parent_call_id: "parent-http-existing-1",
               runtime_source: "synthetic",
               transport: :streamable_http,
               external_ids: %{
                 "session_id" => "session-http-existing-1",
                 "call_id" => "call-http-existing-1",
                 "childID" => "child-http-existing-1"
               },
               stream_cursor: %{
                 :transport => :streamable_http,
                 :event_seq => 2,
                 :child_id => "child-http-existing-1",
                 "offset" => 1
               },
               pane_state: %{
                 title: "Existing HTTP child",
                 stream_entries: [
                   %{
                     event_seq: 2,
                     runtime_seq: 1,
                     token: "first-existing-token",
                     payload: %{
                       "childID" => "child-http-existing-1",
                       "seq" => 1,
                       "token" => "first-existing-token",
                       "cursor" => %{"offset" => 1}
                     }
                   }
                 ]
               }
             }
           ] = routed_child_state.working

    assert routed_child_state.child_pane_registry == %{
             "child-http-existing-1" => "child-pane:stable-existing-http"
           }

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_result,
                      transport: :streamable_http,
                      parent_call_id: "parent-http-existing-1",
                      result: %{
                        "childID" => "child-http-existing-1",
                        "seq" => 2,
                        "token" => "done",
                        "ok" => true
                      },
                      event_seq: 3
                    }},
                   500

    assert_receive {:fake_server_request, raw_request}, 500
    assert raw_request =~ "POST /mcp HTTP/1.1"
    assert raw_request =~ "\"task\":\"route existing child token\""
  end

  defp start_fake_http_mcp_server(
         result \\ %{content: [%{type: "text", text: "pong"}]},
         response_id \\ "call-1"
       ) do
    parent = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = recv_http_request(socket, "")
        send(parent, {:fake_server_request, request})

        response_body =
          Json.encode!(%{
            jsonrpc: "2.0",
            id: response_id,
            result: result
          })
          |> IO.iodata_to_binary()

        response = [
          "HTTP/1.1 200 OK\r\n",
          "content-type: application/json\r\n",
          "content-length: #{byte_size(response_body)}\r\n",
          "connection: close\r\n",
          "\r\n",
          response_body
        ]

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, port: port}}
  end

  defp start_fake_http_mcp_sse_server(events, opts \\ []) when is_list(events) do
    parent = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = recv_http_request(socket, "")
        send(parent, {:fake_server_request, request})

        response_body =
          events
          |> Enum.map(&sse_frame/1)
          |> IO.iodata_to_binary()

        response_headers = [
          "HTTP/1.1 200 OK\r\n",
          "content-type: text/event-stream\r\n",
          "cache-control: no-cache\r\n",
          "content-length: #{byte_size(response_body)}\r\n",
          "connection: close\r\n",
          "\r\n"
        ]

        :ok = :gen_tcp.send(socket, response_headers)
        :ok = send_sse_response_body(socket, response_body, opts)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, port: port}}
  end

  defp start_fake_http_mcp_streaming_sse_server(actions) when is_list(actions) do
    parent = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = recv_http_request(socket, "")
        send(parent, {:fake_server_request, request})

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: text/event-stream\r\n",
            "cache-control: no-cache\r\n",
            "connection: close\r\n",
            "\r\n"
          ])

        Enum.each(actions, fn
          {:send, data} -> :ok = :gen_tcp.send(socket, data)
          {:sleep, ms} -> Process.sleep(ms)
        end)

        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, port: port}}
  end

  defp send_sse_response_body(socket, response_body, opts) do
    case Keyword.get(opts, :body_chunk_size) do
      chunk_size when is_integer(chunk_size) and chunk_size > 0 ->
        response_body
        |> chunk_binary(chunk_size, [])
        |> Enum.each(fn chunk -> :ok = :gen_tcp.send(socket, chunk) end)

        :ok

      _ ->
        :gen_tcp.send(socket, response_body)
    end
  end

  defp chunk_binary("", _chunk_size, acc), do: Enum.reverse(acc)

  defp chunk_binary(binary, chunk_size, acc) when byte_size(binary) <= chunk_size do
    Enum.reverse([binary | acc])
  end

  defp chunk_binary(binary, chunk_size, acc) do
    <<chunk::binary-size(chunk_size), rest::binary>> = binary
    chunk_binary(rest, chunk_size, [chunk | acc])
  end

  defp sse_frame(payload) do
    ["event: message\n", "data: ", Json.encode!(payload), "\n\n"]
  end

  defp recv_http_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} ->
        next = acc <> chunk

        if complete_http_request?(next) do
          {:ok, next}
        else
          recv_http_request(socket, next)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_http_request?(request) do
    with [headers, body] <- String.split(request, "\r\n\r\n", parts: 2),
         [length] <- Regex.run(~r/content-length:\s*(\d+)/i, headers, capture: :all_but_first),
         {content_length, ""} <- Integer.parse(length) do
      byte_size(body) >= content_length
    else
      _ -> false
    end
  end
end
