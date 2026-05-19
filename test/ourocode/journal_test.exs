defmodule Ourocode.JournalTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPanes
  alias Ourocode.Journal

  test "append_returning_event persists normalized events in the exact emitted sequence order" do
    path = journal_path("persisted-sequence-matches-emitted-normalized-events")

    source_events = [
      %{
        type: :parent_call_started,
        parent_call_id: "parent-deterministic-sequence",
        runtime_source: "synthetic-runtime",
        transport: :stdio,
        occurred_at_ms: 1_001,
        method: "tools/call",
        params: %{"name" => "spawn_child"}
      },
      %{
        type: :parent_call_event,
        parent_call_id: "parent-deterministic-sequence",
        runtime_source: "synthetic-runtime",
        transport: :sse,
        external_ids: %{"childID" => "child-deterministic-sequence"},
        occurred_at_ms: 1_002,
        payload: %{"seq" => 1, "token" => "alpha"}
      },
      %{
        type: :parent_call_result,
        parent_call_id: "parent-deterministic-sequence",
        runtime_source: "synthetic-runtime",
        transport: :streamable_http,
        external_ids: %{"childID" => "child-deterministic-sequence"},
        occurred_at_ms: 1_003,
        result: %{"status" => "completed"}
      }
    ]

    emitted_events =
      Enum.map(source_events, fn event ->
        assert {:ok, emitted_event} = Journal.append_returning_event(path, event)
        emitted_event
      end)

    assert Enum.map(emitted_events, & &1.event_seq) == [1, 2, 3]

    assert {:ok, persisted_events} = Journal.replay_normalized_events(path)
    assert persisted_events == emitted_events

    assert Enum.map(persisted_events, & &1.type) == [
             :parent_call_started,
             :parent_call_event,
             :parent_call_result
           ]

    assert Enum.map(persisted_events, & &1.transport) == [:stdio, :sse, :streamable_http]
    assert get_in(Enum.at(persisted_events, 1), [:payload, "token"]) == "alpha"
    assert get_in(Enum.at(persisted_events, 2), [:result, "status"]) == "completed"
  end

  test "append assigns event_seq to events that do not already have one and accepts contiguous explicit values" do
    path = journal_path("assigned-event-seq")

    assert :ok =
             Journal.append(path, %{
               type: :parent_call_event,
               parent_call_id: "parent-assigned-seq",
               runtime_source: "synthetic",
               transport: :stdio,
               occurred_at_ms: 10,
               payload: %{token: "first"}
             })

    assert :ok =
             Journal.append(path, %{
               event_seq: 2,
               type: :parent_call_event,
               parent_call_id: "parent-preserved-seq",
               runtime_source: "synthetic",
               transport: :stdio,
               occurred_at_ms: 20,
               payload: %{token: "preserved"}
             })

    assert :ok =
             Journal.append(path, %{
               type: :parent_call_event,
               parent_call_id: "parent-next-seq",
               runtime_source: "synthetic",
               transport: :stdio,
               occurred_at_ms: 30,
               payload: %{token: "next"}
             })

    assert {:ok, [first, preserved, next]} = Journal.read(path)
    assert first.event_seq == 1
    assert preserved.event_seq == 2
    assert next.event_seq == 3
  end

  test "append rejects explicit event_seq gaps before writing the journal record" do
    path = journal_path("reject-event-seq-gap")

    assert :ok =
             Journal.append(path, %{
               event_seq: 1,
               type: :parent_call_event,
               parent_call_id: "parent-gap-seq",
               runtime_source: "synthetic",
               transport: :stdio,
               occurred_at_ms: 10,
               payload: %{token: "first"}
             })

    assert {:error, {:event_seq_gap, 2, 4}} =
             Journal.append(path, %{
               event_seq: 4,
               type: :parent_call_event,
               parent_call_id: "parent-gap-seq",
               runtime_source: "synthetic",
               transport: :stdio,
               occurred_at_ms: 20,
               payload: %{token: "gap"}
             })

    assert {:ok, entries} = Journal.read_ordered(path)
    assert Enum.map(entries, & &1.event_seq) == [1]
  end

  test "append assigns strictly increasing event_seq values across multiple normalized events" do
    path = journal_path("strictly-monotonic-event-seq")

    events =
      [:stdio, :sse, :streamable_http, :stdio, :sse]
      |> Enum.with_index(1)
      |> Enum.map(fn {transport, index} ->
        %{
          type: :parent_call_event,
          parent_call_id: "parent-monotonic-seq",
          runtime_source: "synthetic-runtime",
          transport: transport,
          occurred_at_ms: 1_000 + index,
          payload: %{token: "token-#{index}"}
        }
      end)

    Enum.each(events, fn event ->
      assert :ok = Journal.append(path, event)
    end)

    assert {:ok, entries} = Journal.read_ordered(path)

    event_seqs = Enum.map(entries, & &1.event_seq)
    assert event_seqs == Enum.to_list(1..length(events))

    assert Enum.chunk_every(event_seqs, 2, 1, :discard)
           |> Enum.all?(fn [left, right] -> left < right end)
  end

  test "append assigns unique increasing event_seq values under concurrent writes" do
    path = journal_path("concurrent-event-seq")
    writer_count = 40
    parent = self()

    writers =
      Enum.map(1..writer_count, fn index ->
        Task.async(fn ->
          send(parent, {:writer_ready, self()})

          receive do
            :append -> :ok
          after
            1_000 -> flunk("writer #{index} did not receive append signal")
          end

          Journal.append(path, %{
            type: :parent_call_event,
            parent_call_id: "parent-concurrent-seq",
            runtime_source: "synthetic-runtime",
            transport: Enum.at([:stdio, :sse, :streamable_http], rem(index, 3)),
            occurred_at_ms: 2_000 + index,
            payload: %{token: "token-#{index}"}
          })
        end)
      end)

    writer_pids =
      Enum.map(1..writer_count, fn _index ->
        assert_receive {:writer_ready, pid}, 1_000
        pid
      end)

    Enum.each(writer_pids, &send(&1, :append))

    assert Enum.map(writers, &Task.await(&1, 5_000)) == List.duplicate(:ok, writer_count)

    assert {:ok, entries} = Journal.read_ordered(path)
    event_seqs = Enum.map(entries, & &1.event_seq)

    assert length(event_seqs) == writer_count
    assert event_seqs == Enum.uniq(event_seqs)
    assert event_seqs == Enum.to_list(1..writer_count)
  end

  test "child event identity derives from journaled metadata and is stable across repeated reads" do
    path = journal_path("stable-child-event-identity")

    assert :ok =
             Journal.append(path, %{
               type: :parent_call_event,
               parent_call_id: "parent-child-event-id-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{"childID" => "child-event-id-1"},
               occurred_at_ms: 1_000,
               payload: %{"seq" => 7, "token" => "stable"}
             })

    assert {:ok, [first_read_event]} = Journal.read_ordered(path)
    assert {:ok, [second_read_event]} = Journal.read_ordered(path)

    assert {:ok, first_identity} = Journal.child_event_identity(first_read_event)
    assert {:ok, second_identity} = Journal.child_event_identity(second_read_event)

    assert first_identity == second_identity

    assert first_identity ==
             "child-event:parent=23:parent-child-event-id-1:child=16:child-event-id-1:runtime=8:opencode:transport=3:sse:event_seq=1:1:runtime_seq=1:7"
  end

  test "normalized raw MCP event metadata round-trips through journal serialization without loss" do
    path = journal_path("raw-mcp-metadata-round-trip")

    events = [
      %{
        event_seq: 1,
        type: :parent_call_event,
        parent_call_id: "parent-raw-metadata-stdio",
        runtime_source: "validation",
        transport: :stdio,
        external_ids: %{"childID" => "child-raw-metadata-stdio"},
        occurred_at_ms: 10_001,
        payload: %{"seq" => 1},
        raw_event: %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{"childID" => "child-raw-metadata-stdio", "seq" => 1},
          process_identifier: %{port: "#Port<0.1>", os_pid: 12_345},
          stream_direction: :inbound,
          timestamp_ms: 10_001,
          raw_payload_ref: "sha256:stdio"
        }
      },
      %{
        event_seq: 2,
        type: :parent_call_event,
        parent_call_id: "parent-raw-metadata-sse",
        runtime_source: "validation",
        transport: :sse,
        external_ids: %{"childID" => "child-raw-metadata-sse"},
        occurred_at_ms: 20_002,
        payload: %{"seq" => 2},
        raw_event: %{
          "event" => "message",
          "id" => "sse-raw-metadata-1",
          "data" => %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{"childID" => "child-raw-metadata-sse", "seq" => 2}
          },
          endpoint_url: "http://localhost:4321/events",
          sse_event_id_present: true,
          received_at_ms: 20_002,
          raw_payload_stored?: false
        }
      },
      %{
        event_seq: 3,
        type: :parent_call_result,
        parent_call_id: "parent-raw-metadata-http",
        runtime_source: "validation",
        transport: :streamable_http,
        external_ids: %{"childID" => "child-raw-metadata-http"},
        occurred_at_ms: 30_003,
        result: %{"ok" => true},
        raw_event: %{
          {"debug", "tuple-key"} => "tuple-key-survives",
          "jsonrpc" => "2.0",
          "id" => "http-raw-metadata-1",
          "result" => %{"childID" => "child-raw-metadata-http", "ok" => true},
          correlation_id: "http-raw-metadata-1",
          headers: [{"content-type", "application/json"}],
          debug_probe: %{sample: true, tags: ["http", "round-trip"]}
        }
      }
    ]

    Enum.each(events, fn event ->
      assert :ok = Journal.append(path, event)
    end)

    assert {:ok, [stdio, sse, http]} = Journal.replay_normalized_events(path)

    assert Enum.map([stdio, sse, http], & &1.raw_event) == Enum.map(events, & &1.raw_event)

    assert stdio.raw_event["method"] == "notifications/progress"
    assert stdio.raw_event.process_identifier == %{port: "#Port<0.1>", os_pid: 12_345}
    assert stdio.raw_event.stream_direction == :inbound
    assert stdio.raw_event.timestamp_ms == 10_001
    assert stdio.raw_event.raw_payload_ref == "sha256:stdio"

    assert sse.raw_event["data"]["params"]["childID"] == "child-raw-metadata-sse"
    assert sse.raw_event.endpoint_url == "http://localhost:4321/events"
    assert sse.raw_event.sse_event_id_present == true
    assert sse.raw_event.received_at_ms == 20_002
    assert sse.raw_event.raw_payload_stored? == false

    assert http.raw_event["result"]["childID"] == "child-raw-metadata-http"
    assert http.raw_event.correlation_id == "http-raw-metadata-1"
    assert http.raw_event.headers == [{"content-type", "application/json"}]
    assert http.raw_event.debug_probe == %{sample: true, tags: ["http", "round-trip"]}
    assert http.raw_event[{"debug", "tuple-key"}] == "tuple-key-survives"
  end

  test "writer persists every rendered sequence entry without dropping entries" do
    path = journal_path("rendered-sequence-no-loss")

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(ChildSessionPanes.new(), %{
               child_id: "child-rendered-journal-1",
               parent_call_id: "parent-rendered-journal-1",
               runtime_source: "synthetic",
               transport: :streamable_http,
               pane_state: %{
                 last_event_seq: 103,
                 stream_entries: [
                   %{event_seq: 101, runtime_seq: 1, token: "alpha", occurred_at_ms: 1_001},
                   %{event_seq: 102, runtime_seq: 2, token: "beta", occurred_at_ms: 1_002},
                   %{event_seq: 103, runtime_seq: 3, token: "done", occurred_at_ms: 1_003}
                 ]
               },
               created_at_ms: 1_000,
               updated_at_ms: 1_004
             })

    assert [%{rendered_sequences: rendered_sequences} = rendered_pane] =
             state
             |> ChildSessionPanes.render()
             |> Map.fetch!(:working)

    assert :ok = Journal.append_rendered_sequences(path, rendered_pane)

    assert {:ok, persisted} = Journal.read_ordered(path)

    assert length(persisted) == length(rendered_sequences)
    assert Enum.map(persisted, & &1.type) == List.duplicate(:rendered_sequence_entry, 3)
    assert Enum.map(persisted, & &1.event_seq) == [1, 2, 3]
    assert Enum.map(persisted, & &1.rendered_event_seq) == [101, 102, 103]

    assert Enum.map(persisted, & &1.rendered_sequence_id) ==
             Enum.map(rendered_sequences, & &1.id)

    assert Enum.map(persisted, &get_in(&1, [:payload, "token"])) == ["alpha", "beta", "done"]
    assert Enum.map(persisted, & &1.occurred_at_ms) == [1_001, 1_002, 1_003]
  end

  test "journal writer preserves the original order of rendered sequence entries" do
    path = journal_path("rendered-sequence-original-order")

    rendered_pane = %{
      id: "child-session:child-rendered-order-1",
      child_id: "child-rendered-order-1",
      updated_at_ms: 2_004,
      pane_state: %{
        stream_entries: [
          %{event_seq: 203, runtime_seq: 3, token: "third-rendered-first", occurred_at_ms: 2_003},
          %{
            event_seq: 201,
            runtime_seq: 1,
            token: "first-rendered-second",
            occurred_at_ms: 2_001
          },
          %{event_seq: 202, runtime_seq: 2, token: "second-rendered-third", occurred_at_ms: 2_002}
        ]
      },
      rendered_sequences: [
        %{
          id: "rendered-order:event=203:index=1",
          pane_id: "child-session:child-rendered-order-1",
          child_id: "child-rendered-order-1",
          event_seq: 203,
          runtime_seq: 3,
          rendered_index: 1
        },
        %{
          id: "rendered-order:event=201:index=2",
          pane_id: "child-session:child-rendered-order-1",
          child_id: "child-rendered-order-1",
          event_seq: 201,
          runtime_seq: 1,
          rendered_index: 2
        },
        %{
          id: "rendered-order:event=202:index=3",
          pane_id: "child-session:child-rendered-order-1",
          child_id: "child-rendered-order-1",
          event_seq: 202,
          runtime_seq: 2,
          rendered_index: 3
        }
      ]
    }

    assert :ok = Journal.append_rendered_sequences(path, rendered_pane)

    assert {:ok, persisted} = Journal.read_ordered(path)

    assert Enum.map(persisted, & &1.event_seq) == [1, 2, 3]
    assert Enum.map(persisted, & &1.rendered_event_seq) == [203, 201, 202]
    assert Enum.map(persisted, & &1.runtime_seq) == [3, 1, 2]
    assert Enum.map(persisted, & &1.rendered_index) == [1, 2, 3]

    assert Enum.map(persisted, & &1.rendered_sequence_id) == [
             "rendered-order:event=203:index=1",
             "rendered-order:event=201:index=2",
             "rendered-order:event=202:index=3"
           ]

    assert Enum.map(persisted, &get_in(&1, [:payload, "token"])) == [
             "third-rendered-first",
             "first-rendered-second",
             "second-rendered-third"
           ]
  end

  test "journal writer persists adjacent duplicate rendered sequence entries as distinct records" do
    path = journal_path("rendered-sequence-adjacent-duplicates")

    duplicate_sequence = %{
      id: "rendered-duplicate:event=301:index=1",
      pane_id: "child-session:child-rendered-duplicates-1",
      child_id: "child-rendered-duplicates-1",
      event_seq: 301,
      runtime_seq: 9,
      rendered_index: 1
    }

    duplicate_stream_entry = %{
      event_seq: 301,
      runtime_seq: 9,
      token: "same-token",
      occurred_at_ms: 3_001
    }

    rendered_pane = %{
      id: "child-session:child-rendered-duplicates-1",
      child_id: "child-rendered-duplicates-1",
      updated_at_ms: 3_004,
      pane_state: %{
        stream_entries: [
          duplicate_stream_entry,
          duplicate_stream_entry,
          %{event_seq: 302, runtime_seq: 10, token: "tail-token", occurred_at_ms: 3_002}
        ]
      },
      rendered_sequences: [
        duplicate_sequence,
        duplicate_sequence,
        %{
          id: "rendered-duplicate:event=302:index=3",
          pane_id: "child-session:child-rendered-duplicates-1",
          child_id: "child-rendered-duplicates-1",
          event_seq: 302,
          runtime_seq: 10,
          rendered_index: 3
        }
      ]
    }

    assert :ok = Journal.append_rendered_sequences(path, rendered_pane)

    assert {:ok, persisted} = Journal.read_ordered(path)
    assert {:ok, raw_contents} = File.read(path)

    assert raw_contents |> String.split("\n", trim: true) |> length() == 3
    assert length(persisted) == 3
    assert Enum.map(persisted, & &1.event_seq) == [1, 2, 3]

    assert Enum.map(persisted, & &1.rendered_sequence_id) == [
             "rendered-duplicate:event=301:index=1",
             "rendered-duplicate:event=301:index=1",
             "rendered-duplicate:event=302:index=3"
           ]

    assert Enum.map(persisted, & &1.rendered_event_seq) == [301, 301, 302]

    assert Enum.map(persisted, &(Map.get(&1, :runtime_seq) || Map.get(&1, "runtime_seq"))) == [
             9,
             9,
             10
           ]

    assert Enum.map(persisted, &get_in(&1, [:payload, "token"])) == [
             "same-token",
             "same-token",
             "tail-token"
           ]
  end

  test "journal-to-render reconciliation fails when completed child stream events are missing from render output" do
    journal_entries = [
      %{
        event_seq: 11,
        type: :parent_call_event,
        child_id: "child-reconcile-1",
        parent_call_id: "parent-reconcile-1",
        transport: :stdio,
        payload: %{"token" => "alpha"},
        occurred_at_ms: 1_011
      },
      %{
        event_seq: 12,
        type: :parent_call_event,
        child_id: "child-reconcile-1",
        parent_call_id: "parent-reconcile-1",
        transport: :stdio,
        payload: %{"token" => "beta"},
        occurred_at_ms: 1_012
      },
      %{
        event_seq: 13,
        type: :child_pane_completed,
        child_id: "child-reconcile-1",
        pane_id: "child-session:child-reconcile-1",
        parent_call_id: "parent-reconcile-1",
        transport: :stdio,
        status: :completed
      }
    ]

    rendered_output = %{
      completed: [
        %{
          id: "child-session:child-reconcile-1",
          child_id: "child-reconcile-1",
          rendered_sequences: [
            %{
              id: "rendered-seq:child-session:child-reconcile-1:event=11:runtime=1:index=1",
              pane_id: "child-session:child-reconcile-1",
              child_id: "child-reconcile-1",
              event_seq: 11,
              runtime_seq: 1,
              rendered_index: 1
            }
          ]
        }
      ]
    }

    assert {:error,
            %{
              type: :journal_to_render_reconciliation,
              status: :failed,
              reason: :journaled_child_stream_events_missing_from_render,
              missing_count: 1,
              missing_rendered_events: [
                %{
                  child_id: "child-reconcile-1",
                  event_seq: 12,
                  parent_call_id: "parent-reconcile-1",
                  transport: :stdio,
                  occurred_at_ms: 1_012
                }
              ]
            }} = Journal.reconcile_completed_child_streams(journal_entries, rendered_output)
  end

  test "journal-to-render reconciliation passes when completed child stream events are rendered" do
    journal_entries = [
      %{
        event_seq: 21,
        type: :parent_call_event,
        payload: %{"childID" => "child-reconcile-ok-1", "token" => "alpha"},
        parent_call_id: "parent-reconcile-ok-1",
        transport: :sse
      },
      %{
        event_seq: 22,
        type: :child_pane_completed,
        child_id: "child-reconcile-ok-1",
        pane_id: "child-session:child-reconcile-ok-1",
        parent_call_id: "parent-reconcile-ok-1",
        transport: :sse,
        status: :completed
      }
    ]

    rendered_entries = [
      %{
        type: :rendered_sequence_entry,
        child_id: "child-reconcile-ok-1",
        pane_id: "child-session:child-reconcile-ok-1",
        rendered_event_seq: 21,
        rendered_sequence_id: "rendered-seq:child-session:child-reconcile-ok-1:event=21"
      }
    ]

    assert {:ok,
            %{
              type: :journal_to_render_reconciliation,
              status: :ok,
              completed_child_ids: ["child-reconcile-ok-1"],
              journaled_event_count: 1,
              rendered_event_count: 1,
              missing_rendered_events: []
            }} = Journal.reconcile_completed_child_streams(journal_entries, rendered_entries)
  end

  test "rendered sequence verifier fails when a rendered sequence id is missing from the journal" do
    journal_entries = [
      %{
        event_seq: 31,
        type: :rendered_sequence_entry,
        child_id: "child-render-journal-missing-1",
        pane_id: "child-session:child-render-journal-missing-1",
        rendered_event_seq: 301,
        runtime_seq: 1,
        rendered_index: 1,
        rendered_sequence_id:
          "rendered-seq:child-session:child-render-journal-missing-1:event=301:runtime=1:index=1"
      }
    ]

    rendered_output = %{
      working: [
        %{
          id: "child-session:child-render-journal-missing-1",
          child_id: "child-render-journal-missing-1",
          rendered_sequences: [
            %{
              id:
                "rendered-seq:child-session:child-render-journal-missing-1:event=301:runtime=1:index=1",
              pane_id: "child-session:child-render-journal-missing-1",
              child_id: "child-render-journal-missing-1",
              event_seq: 301,
              runtime_seq: 1,
              rendered_index: 1
            },
            %{
              id:
                "rendered-seq:child-session:child-render-journal-missing-1:event=302:runtime=2:index=2",
              pane_id: "child-session:child-render-journal-missing-1",
              child_id: "child-render-journal-missing-1",
              event_seq: 302,
              runtime_seq: 2,
              rendered_index: 2
            }
          ]
        }
      ]
    }

    assert {:error,
            %{
              type: :rendered_sequence_journal_reconciliation,
              status: :failed,
              reason: :rendered_sequences_missing_from_journal,
              missing_count: 1,
              journaled_rendered_sequence_count: 1,
              rendered_sequence_count: 2,
              missing_journaled_rendered_sequences: [
                %{
                  rendered_sequence_id:
                    "rendered-seq:child-session:child-render-journal-missing-1:event=302:runtime=2:index=2",
                  child_id: "child-render-journal-missing-1",
                  pane_id: "child-session:child-render-journal-missing-1",
                  rendered_event_seq: 302,
                  runtime_seq: 2,
                  rendered_index: 2
                }
              ]
            }} = Journal.verify_rendered_sequences_journaled(journal_entries, rendered_output)
  end

  test "rendered sequence verifier passes when all rendered sequence ids are journaled" do
    journaled_sequence_id =
      "rendered-seq:child-session:child-render-journal-ok-1:event=401:runtime=1:index=1"

    journal_entries = [
      %{
        "event_seq" => 41,
        "type" => "rendered_sequence_entry",
        "child_id" => "child-render-journal-ok-1",
        "pane_id" => "child-session:child-render-journal-ok-1",
        "rendered_event_seq" => 401,
        "runtime_seq" => 1,
        "rendered_index" => 1,
        "rendered_sequence_id" => journaled_sequence_id
      }
    ]

    rendered_output = [
      %{
        "type" => "rendered_sequence_entry",
        "child_id" => "child-render-journal-ok-1",
        "pane_id" => "child-session:child-render-journal-ok-1",
        "rendered_event_seq" => 401,
        "runtime_seq" => 1,
        "rendered_index" => 1,
        "rendered_sequence_id" => journaled_sequence_id
      }
    ]

    assert {:ok,
            %{
              type: :rendered_sequence_journal_reconciliation,
              status: :ok,
              journaled_rendered_sequence_count: 1,
              rendered_sequence_count: 1,
              journaled_rendered_sequence_ids: [^journaled_sequence_id],
              rendered_sequence_ids: [^journaled_sequence_id],
              missing_journaled_rendered_sequences: []
            }} = Journal.verify_rendered_sequences_journaled(journal_entries, rendered_output)
  end

  test "normalized event no-loss comparison passes for equivalent journaled and source events" do
    source_events = [
      %{
        event_seq: 1,
        type: :parent_call_event,
        transport: :stdio,
        parent_call_id: "parent-no-loss-ok-1",
        runtime_source: "synthetic",
        external_ids: %{"childID" => "child-no-loss-ok-1"},
        payload: %{"seq" => 1, "token" => "alpha"},
        occurred_at_ms: 1_001
      },
      %{
        event_seq: 2,
        type: :parent_call_result,
        transport: :stdio,
        parent_call_id: "parent-no-loss-ok-1",
        runtime_source: "synthetic",
        external_ids: %{"childID" => "child-no-loss-ok-1"},
        result: %{"ok" => true},
        payload: %{"ok" => true},
        occurred_at_ms: 1_002
      }
    ]

    journaled_events = [
      %{
        "event_seq" => 1,
        "type" => "parent_call_event",
        "transport" => "stdio",
        "parent_call_id" => "parent-no-loss-ok-1",
        "runtime_source" => "synthetic",
        "external_ids" => %{"childID" => "child-no-loss-ok-1"},
        "payload" => %{"seq" => 1, "token" => "alpha"},
        "occurred_at_ms" => 1_001
      },
      %{
        "event_seq" => 2,
        "type" => "parent_call_result",
        "transport" => "stdio",
        "parent_call_id" => "parent-no-loss-ok-1",
        "runtime_source" => "synthetic",
        "external_ids" => %{"childID" => "child-no-loss-ok-1"},
        "result" => %{"ok" => true},
        "payload" => %{"ok" => true},
        "occurred_at_ms" => 1_002
      }
    ]

    assert {:ok,
            %{
              type: :normalized_event_no_loss_comparison,
              status: :ok,
              source_event_count: 2,
              journaled_event_count: 2,
              missing_count: 0,
              extra_count: 0,
              mismatched_count: 0,
              missing_normalized_events: [],
              extra_normalized_events: [],
              mismatched_normalized_events: []
            }} = Journal.compare_normalized_events(journaled_events, source_events)
  end

  test "normalized event no-loss comparison ignores raw transport frame differences" do
    source_events = [
      %{
        event_seq: 1,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-raw-frame-equivalent-1",
        runtime_source: "synthetic",
        external_ids: %{"childID" => "child-raw-frame-equivalent-1"},
        payload: %{
          "childID" => "child-raw-frame-equivalent-1",
          "seq" => 1,
          "token" => "alpha"
        },
        notification: %{
          "method" => "notifications/progress",
          "params" => %{
            "childID" => "child-raw-frame-equivalent-1",
            "seq" => 1,
            "token" => "alpha"
          }
        },
        raw_event: %{
          "event" => "message",
          "id" => "source-frame-id",
          "data" => %{
            "method" => "notifications/progress",
            "params" => %{
              "childID" => "child-raw-frame-equivalent-1",
              "seq" => 1,
              "token" => "alpha"
            }
          }
        },
        occurred_at_ms: 22_001
      }
    ]

    journaled_events = [
      %{
        "event_seq" => 1,
        "type" => "parent_call_event",
        "transport" => "sse",
        "parent_call_id" => "parent-raw-frame-equivalent-1",
        "runtime_source" => "synthetic",
        "external_ids" => %{"childID" => "child-raw-frame-equivalent-1"},
        "payload" => %{
          "childID" => "child-raw-frame-equivalent-1",
          "seq" => 1,
          "token" => "alpha"
        },
        "notification" => %{
          "method" => "notifications/progress",
          "params" => %{
            "childID" => "child-raw-frame-equivalent-1",
            "seq" => 1,
            "token" => "alpha"
          }
        },
        "raw_event" => %{
          "event" => "message",
          "id" => "journal-frame-id",
          "data" => %{
            "method" => "notifications/progress",
            "params" => %{
              "childID" => "child-raw-frame-equivalent-1",
              "seq" => 1,
              "token" => "alpha"
            }
          },
          "comment" => "transport-only diagnostic metadata"
        },
        "occurred_at_ms" => 22_001
      }
    ]

    assert {:ok,
            %{
              status: :ok,
              missing_count: 0,
              extra_count: 0,
              mismatched_count: 0
            }} = Journal.compare_normalized_events(journaled_events, source_events)
  end

  test "source transport validation ignores raw SSE frame differences after normalization" do
    decoded = %{
      "method" => "notifications/progress",
      "params" => %{
        "childID" => "child-raw-sse-equivalent-1",
        "seq" => 1,
        "token" => "alpha"
      }
    }

    journaled_events = [
      %{
        "event_seq" => 1,
        "type" => "parent_call_event",
        "transport" => "sse",
        "parent_call_id" => "parent-raw-sse-equivalent-1",
        "runtime_source" => "validation-test",
        "external_ids" => %{"childID" => "child-raw-sse-equivalent-1"},
        "notification" => decoded,
        "payload" => Map.fetch!(decoded, "params"),
        "raw_event" => %{
          "event" => "message",
          "id" => "journal-sse-id",
          "data" => decoded
        },
        "occurred_at_ms" => 22_002
      }
    ]

    source_transport_events = [
      %{
        transport: :sse,
        frame:
          ": keepalive comment ignored by parser\n" <>
            "event: message\n" <>
            "id: source-sse-id\n" <>
            "data: #{Ourocode.Json.encode!(decoded)}\n\n",
        context: %{
          event_seq: 1,
          parent_call_id: "parent-raw-sse-equivalent-1",
          runtime_source: "validation-test",
          external_ids: %{},
          occurred_at_ms: 22_002
        }
      }
    ]

    assert {:ok,
            %{
              status: :ok,
              source_event_count: 1,
              journaled_event_count: 1,
              missing_count: 0,
              extra_count: 0,
              mismatched_count: 0,
              source_normalization: %{
                status: :ok,
                normalized_event_count: 1,
                transports: [:sse]
              }
            }} =
             Journal.compare_source_transport_events(journaled_events, source_transport_events)
  end

  test "validation pipeline normalizes stdio source transport events before no-loss comparison" do
    decoded = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{"childID" => "child-pipeline-stdio", "seq" => 1, "token" => "alpha"}
    }

    line = decoded |> Ourocode.Json.encode!() |> IO.iodata_to_binary()

    journaled_events = [
      %{
        "event_seq" => 1,
        "type" => "parent_call_event",
        "transport" => "stdio",
        "parent_call_id" => "parent-pipeline-stdio",
        "runtime_source" => "validation-test",
        "external_ids" => %{"childID" => "child-pipeline-stdio"},
        "notification" => decoded,
        "payload" => %{"childID" => "child-pipeline-stdio", "seq" => 1, "token" => "alpha"},
        "raw_event" => decoded,
        "occurred_at_ms" => 21_001
      }
    ]

    source_transport_events = [
      %{
        transport: :stdio,
        line: line,
        context: %{
          event_seq: 1,
          parent_call_id: "parent-pipeline-stdio",
          runtime_source: "validation-test",
          external_ids: %{},
          occurred_at_ms: 21_001
        }
      }
    ]

    assert {:ok,
            %{
              status: :ok,
              source_event_count: 1,
              journaled_event_count: 1,
              source_normalization: %{
                type: :source_transport_event_normalization,
                status: :ok,
                source_event_count: 1,
                normalized_event_count: 1,
                transports: [:stdio]
              }
            }} =
             Journal.compare_source_transport_events(journaled_events, source_transport_events)
  end

  test "validation pipeline normalizes SSE source transport events before no-loss comparison" do
    parsed_event = %{
      "event" => "message",
      "id" => "sse-event-1",
      "data" => %{
        "method" => "notifications/progress",
        "params" => %{"childID" => "child-pipeline-sse", "seq" => 2, "token" => "bravo"}
      }
    }

    journaled_events = [
      %{
        "event_seq" => 2,
        "type" => "parent_call_event",
        "transport" => "sse",
        "parent_call_id" => "parent-pipeline-sse",
        "runtime_source" => "validation-test",
        "external_ids" => %{"childID" => "child-pipeline-sse"},
        "notification" => Map.fetch!(parsed_event, "data"),
        "payload" => %{"childID" => "child-pipeline-sse", "seq" => 2, "token" => "bravo"},
        "raw_event" => parsed_event,
        "occurred_at_ms" => 21_002,
        "headers" => [["content-type", "text/event-stream"]],
        "status" => 200
      }
    ]

    source_transport_events = [
      %{
        transport: :sse,
        event: parsed_event,
        context: %{
          event_seq: 2,
          parent_call_id: "parent-pipeline-sse",
          runtime_source: "validation-test",
          external_ids: %{},
          occurred_at_ms: 21_002,
          headers: [{"content-type", "text/event-stream"}],
          status: 200
        }
      }
    ]

    assert {:ok,
            %{
              status: :ok,
              source_normalization: %{
                status: :ok,
                normalized_event_count: 1,
                transports: [:sse]
              }
            }} =
             Journal.compare_source_transport_events(journaled_events, source_transport_events)
  end

  test "validation pipeline normalizes streamable HTTP source transport events before no-loss comparison" do
    decoded = %{
      "jsonrpc" => "2.0",
      "id" => "http-event-1",
      "result" => %{
        "type" => "parent_call_result",
        "payload" => %{"childID" => "child-pipeline-http", "token" => "charlie"},
        "external_ids" => %{"childID" => "child-pipeline-http"}
      }
    }

    body = decoded |> Ourocode.Json.encode!() |> IO.iodata_to_binary()
    headers = [{"content-type", "application/json"}]

    journaled_events = [
      %{
        "event_seq" => 3,
        "type" => "parent_call_result",
        "transport" => "streamable_http",
        "parent_call_id" => "parent-pipeline-http",
        "runtime_source" => "validation-test",
        "external_ids" => %{},
        "request_id" => "http-event-1",
        "result" => %{
          "type" => "parent_call_result",
          "payload" => %{"childID" => "child-pipeline-http", "token" => "charlie"},
          "external_ids" => %{"childID" => "child-pipeline-http"}
        },
        "raw_event" => decoded,
        "occurred_at_ms" => 21_003,
        "headers" => [["content-type", "application/json"]],
        "status" => 200
      }
    ]

    source_transport_events = [
      %{
        transport: :streamable_http,
        status: 200,
        headers: headers,
        body: body,
        context: %{
          event_seq: 3,
          parent_call_id: "parent-pipeline-http",
          runtime_source: "validation-test",
          external_ids: %{},
          occurred_at_ms: 21_003
        }
      }
    ]

    assert {:ok,
            %{
              status: :ok,
              source_normalization: %{
                status: :ok,
                normalized_event_count: 1,
                transports: [:streamable_http]
              }
            }} =
             Journal.compare_source_transport_events(journaled_events, source_transport_events)
  end

  test "normalized event no-loss comparison reports source events missing from the journal" do
    source_events = [
      normalized_event(1, "alpha"),
      normalized_event(2, "beta"),
      normalized_event(3, "gamma")
    ]

    journaled_events = [
      normalized_event(1, "alpha"),
      normalized_event(3, "gamma")
    ]

    assert {:error,
            %{
              type: :normalized_event_no_loss_comparison,
              status: :failed,
              reason: :normalized_event_no_loss_comparison_failed,
              missing_count: 1,
              extra_count: 0,
              mismatched_count: 0,
              missing_normalized_events: [
                %{
                  identity: %{kind: :event_seq, value: 2, occurrence: 1},
                  event_index: 1,
                  event: %{"event_seq" => 2, "payload" => %{"token" => "beta"}}
                }
              ]
            }} = Journal.compare_normalized_events(journaled_events, source_events)
  end

  test "normalized event no-loss comparison reports journal records with no source event" do
    source_events = [
      normalized_event(1, "alpha")
    ]

    journaled_events = [
      normalized_event(1, "alpha"),
      normalized_event(2, "unexpected")
    ]

    assert {:error,
            %{
              status: :failed,
              missing_count: 0,
              extra_count: 1,
              mismatched_count: 0,
              extra_normalized_events: [
                %{
                  identity: %{kind: :event_seq, value: 2, occurrence: 1},
                  event_index: 1,
                  event: %{"event_seq" => 2, "payload" => %{"token" => "unexpected"}}
                }
              ]
            }} = Journal.compare_normalized_events(journaled_events, source_events)
  end

  test "normalized event no-loss comparison reports mismatched normalized events" do
    source_events = [
      %{
        event_seq: 1,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-mismatch-1",
        payload: %{token: "source-token"}
      }
    ]

    journaled_events = [
      %{
        "event_seq" => 1,
        "type" => "parent_call_event",
        "transport" => "sse",
        "parent_call_id" => "parent-mismatch-1",
        "payload" => %{"token" => "journal-token"}
      }
    ]

    assert {:error,
            %{
              status: :failed,
              missing_count: 0,
              extra_count: 0,
              mismatched_count: 1,
              mismatched_normalized_events: [
                %{
                  identity: %{kind: :event_seq, value: 1, occurrence: 1},
                  source_index: 0,
                  journaled_index: 0,
                  differing_fields: ["payload"],
                  source_event: %{"payload" => %{"token" => "source-token"}},
                  journaled_event: %{"payload" => %{"token" => "journal-token"}}
                }
              ]
            }} = Journal.compare_normalized_events(journaled_events, source_events)
  end

  defp journal_path(name) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")

    File.rm(path)
    path
  end

  defp normalized_event(event_seq, token) do
    %{
      event_seq: event_seq,
      payload: %{token: token}
    }
  end
end
