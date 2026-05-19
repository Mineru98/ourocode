defmodule Ourocode.Dashboard.ChildSessionPanesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPanes
  alias Ourocode.Journal
  alias Ourocode.Journal.RelationshipRecoveryIndex
  alias Ourocode.Journal.RelationshipRecoveryRecord

  test "child pane model creation stores first-class pane linked to parent with stable id" do
    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(ChildSessionPanes.new(), %{
               child_id: "child-create-1",
               parent_call_id: "parent-create-1",
               runtime_source: "synthetic",
               transport: :stdio,
               external_ids: %{session_id: "session-create-1"},
               stream_cursor: %{event_seq: 7},
               pane_state: %{title: "Created child pane"},
               created_at_ms: 100,
               updated_at_ms: 120
             })

    pane_id = ChildSessionPanes.child_pane_id("child-create-1")

    assert pane_id == "child-session:child-create-1"
    assert state.focused == pane_id
    assert state.open == [pane_id]
    assert state.child_pane_registry == %{"child-create-1" => pane_id}

    assert {:ok,
            %{
              id: ^pane_id,
              kind: :child_session,
              status: :working,
              child_id: "child-create-1",
              parent_call_id: "parent-create-1",
              runtime_source: "synthetic",
              transport: :stdio,
              external_ids: %{"childID" => "child-create-1", session_id: "session-create-1"},
              stream_cursor: %{
                event_seq: 7,
                transport: :stdio,
                child_id: "child-create-1"
              },
              pane_state: %{
                open?: true,
                focused?: false,
                renderer: :default_child_session,
                title: "Created child pane"
              },
              created_at_ms: 100,
              updated_at_ms: 120
            }} = ChildSessionPanes.fetch_pane(state, pane_id)
  end

  test "child pane reads after updates preserve existing child and parent ids" do
    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(ChildSessionPanes.new(), %{
               child_id: "child-update-1",
               parent_call_id: "parent-update-1",
               runtime_source: "synthetic",
               transport: :sse,
               external_ids: %{session_id: "session-update-1"},
               stream_cursor: %{event_seq: 1},
               pane_state: %{title: "Original child pane"},
               created_at_ms: 100,
               updated_at_ms: 100
             })

    pane_id = ChildSessionPanes.child_pane_id("child-update-1")

    assert {:ok, state} =
             ChildSessionPanes.update_child_pane(state, pane_id, %{
               id: "child-session:should-not-replace",
               pane_id: "child-session:should-not-replace",
               child_id: "child-update-rewritten",
               parent_call_id: "parent-update-rewritten",
               runtime_source: "opencode",
               transport: :streamable_http,
               external_ids: %{thread_id: "thread-update-1"},
               stream_cursor: %{event_seq: 2, child_id: "child-update-rewritten"},
               pane_state: %{title: "Updated child pane", last_event_seq: 2},
               updated_at_ms: 200
             })

    assert state.focused == pane_id
    assert state.open == [pane_id]
    assert state.child_pane_registry == %{"child-update-1" => pane_id}
    assert [%{id: ^pane_id}] = state.working
    assert state.completed == []

    assert {:ok,
            %{
              id: ^pane_id,
              child_id: "child-update-1",
              parent_call_id: "parent-update-1",
              runtime_source: "opencode",
              transport: :streamable_http,
              external_ids: %{
                "childID" => "child-update-1",
                session_id: "session-update-1",
                thread_id: "thread-update-1"
              },
              stream_cursor: %{
                event_seq: 2,
                transport: :streamable_http,
                child_id: "child-update-1"
              },
              pane_state: %{
                title: "Updated child pane",
                last_event_seq: 2
              },
              created_at_ms: 100,
              updated_at_ms: 200
            }} = ChildSessionPanes.fetch_pane(state, pane_id)

    assert {:error, :child_session_pane_not_found} =
             ChildSessionPanes.fetch_pane(state, "child-session:should-not-replace")
  end

  test "renderer records every rendered stream sequence with a stable identifier" do
    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(ChildSessionPanes.new(), %{
               child_id: "child-rendered-seq-1",
               parent_call_id: "parent-rendered-seq-1",
               runtime_source: "synthetic",
               transport: :stdio,
               pane_state: %{
                 stream_entries: [
                   %{event_seq: 10, runtime_seq: 1, token: "alpha"},
                   %{event_seq: 11, runtime_seq: 2, token: "beta"},
                   %{event_seq: 12, runtime_seq: 3, token: "done"}
                 ],
                 last_event_seq: 12
               },
               created_at_ms: 100,
               updated_at_ms: 120
             })

    rendered = ChildSessionPanes.render(state)

    assert [
             %{
               id: pane_id,
               rendered_sequences: rendered_sequences,
               pane_state: %{stream_entries: rendered_stream_entries}
             }
           ] = rendered.working

    assert pane_id == "child-session:child-rendered-seq-1"

    assert Enum.map(rendered_sequences, & &1.id) == [
             "rendered-seq:child-session:child-rendered-seq-1:event=10:runtime=1:index=1",
             "rendered-seq:child-session:child-rendered-seq-1:event=11:runtime=2:index=2",
             "rendered-seq:child-session:child-rendered-seq-1:event=12:runtime=3:index=3"
           ]

    assert Enum.map(
             rendered_sequences,
             &Map.take(&1, [:event_seq, :runtime_seq, :rendered_index])
           ) ==
             [
               %{event_seq: 10, runtime_seq: 1, rendered_index: 1},
               %{event_seq: 11, runtime_seq: 2, rendered_index: 2},
               %{event_seq: 12, runtime_seq: 3, rendered_index: 3}
             ]

    assert Enum.map(rendered_stream_entries, & &1.rendered_sequence_id) ==
             Enum.map(rendered_sequences, & &1.id)

    assert rendered_sequences ==
             state
             |> ChildSessionPanes.render()
             |> get_in([:working, Access.at(0), :rendered_sequences])
  end

  test "runtime child event identity is stable across repeated pane renders" do
    state =
      ChildSessionPanes.apply_event(ChildSessionPanes.new(), %{
        event_seq: 41,
        type: :parent_call_event,
        parent_call_id: "parent-child-event-render-1",
        runtime_source: "opencode",
        transport: :streamable_http,
        external_ids: %{"childID" => "child-event-render-1"},
        occurred_at_ms: 4_100,
        notification: %{
          "method" => "notifications/progress",
          "params" => %{
            "childID" => "child-event-render-1",
            "seq" => 9,
            "token" => "rendered"
          }
        }
      })

    first_render = ChildSessionPanes.render(state)
    second_render = ChildSessionPanes.render(state)

    first_sequence = first_render |> get_in([:working, Access.at(0), :rendered_sequences]) |> hd()

    second_sequence =
      second_render |> get_in([:working, Access.at(0), :rendered_sequences]) |> hd()

    first_entry =
      first_render |> get_in([:working, Access.at(0), :pane_state, :stream_entries]) |> hd()

    second_entry =
      second_render |> get_in([:working, Access.at(0), :pane_state, :stream_entries]) |> hd()

    expected_child_event_id =
      "child-event:parent=27:parent-child-event-render-1:child=20:child-event-render-1:runtime=8:opencode:transport=15:streamable_http:event_seq=2:41:runtime_seq=1:9"

    assert first_sequence.child_event_id == expected_child_event_id
    assert second_sequence.child_event_id == expected_child_event_id
    assert first_sequence.id == "rendered-seq:" <> expected_child_event_id
    assert second_sequence.id == first_sequence.id
    assert first_entry.child_event_id == expected_child_event_id
    assert second_entry.child_event_id == expected_child_event_id
  end

  test "duplicate journaled child events with the same identity are suppressed before rendering" do
    duplicate_child_event_id = "child-event:journaled-duplicate-identity-1"

    event = fn event_seq, token ->
      %{
        event_seq: event_seq,
        type: :parent_call_event,
        parent_call_id: "parent-child-dedupe-1",
        runtime_source: "opencode",
        transport: :sse,
        child_event_id: duplicate_child_event_id,
        external_ids: %{"childID" => "child-dedupe-1"},
        occurred_at_ms: 5_000 + event_seq,
        notification: %{
          "method" => "notifications/progress",
          "params" => %{
            "childID" => "child-dedupe-1",
            "seq" => event_seq,
            "token" => token
          }
        }
      }
    end

    state =
      ChildSessionPanes.new()
      |> ChildSessionPanes.apply_event(event.(51, "first-entry"))
      |> ChildSessionPanes.apply_event(event.(52, "duplicate-entry"))

    assert [
             %{
               pane_state: %{
                 stream_entries: [
                   %{
                     event_seq: 51,
                     token: "first-entry",
                     child_event_id: ^duplicate_child_event_id
                   }
                 ]
               }
             }
           ] = state.working

    rendered = ChildSessionPanes.render(state)

    assert [
             %{
               stream_event_count: 1,
               rendered_sequences: [
                 %{
                   id: "rendered-seq:" <> ^duplicate_child_event_id,
                   child_event_id: ^duplicate_child_event_id,
                   event_seq: 51
                 }
               ],
               pane_state: %{
                 stream_entries: [
                   %{
                     token: "first-entry",
                     child_event_id: ^duplicate_child_event_id
                   }
                 ]
               }
             }
           ] = rendered.working
  end

  test "journal recovery reconstructs stable child pane identities after restart" do
    recovered =
      ChildSessionPanes.recover_from_journal([
        %{
          "type" => "child_pane_registered",
          "pane_id" => "child-pane:journald-alpha",
          "child_id" => "runtime-child-alpha",
          "parent_call_id" => "parent-journal-restart-1",
          "runtime_source" => "opencode",
          "transport" => "sse",
          "external_ids" => %{
            "session_id" => "runtime-session-alpha",
            "thread_id" => "runtime-thread-alpha"
          },
          "stream_cursor" => %{"event_id" => "sse-1", "event_seq" => 1},
          "pane_state" => %{
            "title" => "Recovered child",
            "last_event_seq" => 1,
            "stream_entries" => [%{"event_seq" => 1, "token" => "first"}]
          },
          "created_at_ms" => "1",
          "updated_at_ms" => "2"
        },
        %{
          type: :child_pane_focused,
          pane_id: "child-pane:journald-alpha",
          child_id: "runtime-child-alpha",
          parent_call_id: "parent-journal-restart-1",
          runtime_source: "opencode",
          transport: :sse,
          pane_state: %{focused?: true, last_event_seq: 1},
          updated_at_ms: 3
        }
      ])

    assert recovered.child_pane_registry == %{
             "runtime-child-alpha" => "child-pane:journald-alpha"
           }

    assert recovered.focused == "child-pane:journald-alpha"
    assert recovered.open == ["child-pane:journald-alpha"]

    assert [
             %{
               id: "child-pane:journald-alpha",
               child_id: "runtime-child-alpha",
               parent_call_id: "parent-journal-restart-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "session_id" => "runtime-session-alpha",
                 "thread_id" => "runtime-thread-alpha",
                 "childID" => "runtime-child-alpha"
               },
               stream_cursor: %{
                 "event_id" => "sse-1",
                 "event_seq" => 1,
                 transport: :sse,
                 child_id: "runtime-child-alpha"
               },
               pane_state: %{
                 title: "Recovered child",
                 focused?: true,
                 last_event_seq: 1,
                 stream_entries: [%{event_seq: 1, token: "first"}]
               },
               created_at_ms: 1,
               updated_at_ms: 3
             }
           ] = recovered.working

    after_stream =
      ChildSessionPanes.apply_event(recovered, %{
        event_seq: 4,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-journal-restart-1",
        runtime_source: "opencode",
        external_ids: %{"session_id" => "runtime-session-alpha"},
        occurred_at_ms: 4,
        notification: %{
          "method" => "notifications/progress",
          "params" => %{"childID" => "runtime-child-alpha", "seq" => 2, "token" => "second"}
        }
      })

    assert [
             %{
               id: "child-pane:journald-alpha",
               child_id: "runtime-child-alpha",
               stream_cursor: %{event_seq: 4, child_id: "runtime-child-alpha"},
               pane_state: %{
                 last_event_seq: 4,
                 stream_entries: [
                   %{event_seq: 1, token: "first"},
                   %{event_seq: 4, token: "second"}
                 ]
               }
             }
           ] = after_stream.working

    assert after_stream.child_pane_registry == recovered.child_pane_registry
    assert after_stream.open == ["child-pane:journald-alpha"]
  end

  test "file journal recovery reconstructs pane-local state after restart" do
    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-child-pane-recovery-#{System.unique_integer()}.jsonl"
      )

    try do
      :ok =
        Journal.append(journal_path, %{
          event_seq: 1,
          type: :child_pane_registered,
          pane_id: "child-pane:persisted-local-state",
          child_id: "runtime-child-persisted",
          parent_call_id: "parent-journal-restart-2",
          runtime_source: "codex",
          transport: :stdio,
          external_ids: %{
            native_session_id: "native-session-persisted",
            thread_id: "thread-persisted"
          },
          stream_cursor: %{offset: 42, event_seq: 7},
          pane_state: %{
            title: "Persisted pane",
            renderer: :trusted_plugin_renderer,
            last_event_seq: 7,
            stream_entries: [
              %{event_seq: 6, token: "before"},
              %{event_seq: 7, token: "restart"}
            ],
            local_filter: "errors-only"
          },
          created_at_ms: 600,
          updated_at_ms: 700
        })

      :ok =
        Journal.append(journal_path, %{
          event_seq: 2,
          type: :child_pane_focused,
          pane_id: "child-pane:persisted-local-state",
          child_id: "runtime-child-persisted",
          parent_call_id: "parent-journal-restart-2",
          runtime_source: "codex",
          transport: :stdio,
          pane_state: %{focused?: true, selected_tab: "events"},
          updated_at_ms: 800
        })

      assert {:ok, events} = Journal.read_ordered(journal_path)
      recovered = ChildSessionPanes.recover_from_journal(events)

      assert recovered.child_pane_registry == %{
               "runtime-child-persisted" => "child-pane:persisted-local-state"
             }

      assert recovered.focused == "child-pane:persisted-local-state"
      assert recovered.open == ["child-pane:persisted-local-state"]

      assert [
               %{
                 id: "child-pane:persisted-local-state",
                 child_id: "runtime-child-persisted",
                 parent_call_id: "parent-journal-restart-2",
                 runtime_source: "codex",
                 transport: :stdio,
                 stream_cursor: %{
                   "offset" => 42,
                   "event_seq" => 7,
                   transport: :stdio,
                   child_id: "runtime-child-persisted"
                 },
                 pane_state: %{
                   :title => "Persisted pane",
                   :renderer => :trusted_plugin_renderer,
                   :focused? => true,
                   "selected_tab" => "events",
                   "local_filter" => "errors-only",
                   last_event_seq: 7,
                   stream_entries: [
                     %{event_seq: 6, token: "before"},
                     %{event_seq: 7, token: "restart"}
                   ]
                 },
                 created_at_ms: 600,
                 updated_at_ms: 800
               }
             ] = recovered.working
    after
      File.rm(journal_path)
    end
  end

  test "restart recovery restores reconstructed mappings into live registry without duplicates" do
    assert {:ok, live_state} =
             ChildSessionPanes.register_child_pane(ChildSessionPanes.new(), %{
               child_id: "child-restart-live-1",
               parent_call_id: "parent-restart-live-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "session_id" => "session-restart-live-1",
                 "thread_id" => "thread-restart-live-1"
               },
               pane_state: %{title: "Live pane", last_event_seq: 6},
               created_at_ms: 60,
               updated_at_ms: 60
             })

    live_state = Map.delete(live_state, :child_pane_registry)

    assert {:ok, recovery_index} =
             RelationshipRecoveryIndex.build([
               relationship_record(
                 event_seq: 5,
                 parent_call_id: "parent-restart-live-1",
                 child_id: "child-restart-live-1",
                 pane_id: "child-pane:journal-restart-live-1",
                 runtime_source: "opencode",
                 transport: :sse,
                 external_ids: %{
                   "session_id" => "session-restart-live-1",
                   "thread_id" => "thread-restart-live-1",
                   "childID" => "child-restart-live-1"
                 },
                 stream_cursor: %{"event_id" => "evt-restart-5", event_seq: 5},
                 pane_state: %{
                   "title" => "Recovered pane",
                   "last_event_seq" => 5,
                   "stream_entries" => [%{"event_seq" => 5, "token" => "before restart"}]
                 },
                 occurred_at_ms: 50,
                 created_at_ms: 50,
                 updated_at_ms: 55,
                 status: :working
               )
             ])

    assert {:ok, restored} =
             ChildSessionPanes.restore_recovered_relationships(live_state, recovery_index)

    assert restored.child_pane_registry == %{
             "child-restart-live-1" => "child-session:child-restart-live-1"
           }

    assert restored.open == ["child-session:child-restart-live-1"]
    assert restored.focused == "child-session:child-restart-live-1"
    assert restored.completed == []

    assert [
             %{
               id: "child-session:child-restart-live-1",
               child_id: "child-restart-live-1",
               parent_call_id: "parent-restart-live-1",
               external_ids: %{
                 "session_id" => "session-restart-live-1",
                 "thread_id" => "thread-restart-live-1",
                 "childID" => "child-restart-live-1"
               },
               stream_cursor: %{
                 "event_id" => "evt-restart-5",
                 event_seq: 5,
                 transport: :sse,
                 child_id: "child-restart-live-1"
               },
               pane_state: %{
                 title: "Recovered pane",
                 last_event_seq: 5,
                 stream_entries: [
                   %{event_seq: 5, token: "before restart"}
                 ]
               }
             }
           ] = restored.working

    assert length(restored.working) == 1

    assert {:ok, restored_again} =
             ChildSessionPanes.restore_recovered_relationships(restored, recovery_index)

    assert restored_again.child_pane_registry == restored.child_pane_registry
    assert restored_again.open == restored.open
    assert length(restored_again.working) == 1
    assert [%{pane_state: %{stream_entries: restored_entries}}] = restored_again.working
    assert length(restored_entries) == 1
  end

  test "runtime replay resumes after each recovered pane cursor without duplicate stream entries" do
    assert {:ok, recovery_index} =
             RelationshipRecoveryIndex.build([
               relationship_record(
                 event_seq: 2,
                 parent_call_id: "parent-cursor-replay-1",
                 child_id: "child-cursor-a",
                 pane_id: "child-pane:cursor-a",
                 runtime_source: "opencode",
                 transport: :sse,
                 external_ids: %{
                   "session_id" => "session-cursor-a",
                   "childID" => "child-cursor-a"
                 },
                 stream_cursor: %{event_seq: 2},
                 acknowledged_stream_cursor: %{:event_seq => 2, "event_id" => "evt-a-2"},
                 pane_state: %{"last_event_seq" => 2},
                 occurred_at_ms: 20
               ),
               relationship_record(
                 event_seq: 4,
                 parent_call_id: "parent-cursor-replay-1",
                 child_id: "child-cursor-b",
                 pane_id: "child-pane:cursor-b",
                 runtime_source: "opencode",
                 transport: :sse,
                 external_ids: %{
                   "session_id" => "session-cursor-b",
                   "childID" => "child-cursor-b"
                 },
                 stream_cursor: %{event_seq: 4},
                 acknowledged_stream_cursor: %{:event_seq => 4, "event_id" => "evt-b-4"},
                 pane_state: %{"last_event_seq" => 4},
                 occurred_at_ms: 40
               )
             ])

    assert {:ok, restored} =
             ChildSessionPanes.restore_recovered_relationships(
               ChildSessionPanes.new(),
               recovery_index
             )

    replay_event = fn child_id, session_id, event_seq, token ->
      %{
        event_seq: event_seq,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-cursor-replay-1",
        runtime_source: "opencode",
        external_ids: %{"session_id" => session_id},
        occurred_at_ms: event_seq * 10,
        notification: %{
          "method" => "notifications/progress",
          "params" => %{"childID" => child_id, "seq" => event_seq, "token" => token}
        }
      }
    end

    replayed =
      restored
      |> ChildSessionPanes.apply_event(
        replay_event.("child-cursor-a", "session-cursor-a", 2, "duplicate-a")
      )
      |> ChildSessionPanes.apply_event(
        replay_event.("child-cursor-a", "session-cursor-a", 3, "new-a")
      )
      |> ChildSessionPanes.apply_event(
        replay_event.("child-cursor-b", "session-cursor-b", 4, "duplicate-b")
      )
      |> ChildSessionPanes.apply_event(
        replay_event.("child-cursor-b", "session-cursor-b", 5, "new-b")
      )

    assert [
             %{child_id: "child-cursor-a", pane_state: %{stream_entries: entries_a}},
             %{child_id: "child-cursor-b", pane_state: %{stream_entries: entries_b}}
           ] = Enum.sort_by(replayed.working, & &1.child_id)

    assert Enum.map(entries_a, & &1.token) == ["new-a"]
    assert Enum.map(entries_b, & &1.token) == ["new-b"]
    assert Enum.map(entries_a, & &1.event_seq) == [3]
    assert Enum.map(entries_b, & &1.event_seq) == [5]
  end

  test "recovered journal entries merge into live child stream exactly once without skipping unseen events" do
    assert {:ok, live_state} =
             ChildSessionPanes.register_child_pane(ChildSessionPanes.new(), %{
               child_id: "child-reconcile-live-1",
               parent_call_id: "parent-reconcile-live-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "session_id" => "session-reconcile-live-1",
                 "childID" => "child-reconcile-live-1"
               },
               pane_state: %{
                 title: "Live child",
                 last_event_seq: 1,
                 stream_entries: [
                   %{
                     event_seq: 1,
                     runtime_seq: 1,
                     token: "already-live",
                     child_event_id: "child-event:reconcile-live-1"
                   }
                 ]
               },
               stream_cursor: %{event_seq: 1},
               created_at_ms: 10,
               updated_at_ms: 10
             })

    records =
      [
        {1, "already-live", "child-event:reconcile-live-1"},
        {2, "journal-unseen-a", "child-event:reconcile-live-2"},
        {3, "journal-unseen-b", "child-event:reconcile-live-3"}
      ]
      |> Enum.map(fn {event_seq, token, child_event_id} ->
        relationship_record(
          event_seq: event_seq,
          event_type: :parent_call_event,
          parent_call_id: "parent-reconcile-live-1",
          child_id: "child-reconcile-live-1",
          pane_id: "child-session:child-reconcile-live-1",
          runtime_source: "opencode",
          transport: :sse,
          external_ids: %{
            "session_id" => "session-reconcile-live-1",
            "childID" => "child-reconcile-live-1"
          },
          stream_cursor: %{event_seq: event_seq, child_id: "child-reconcile-live-1"},
          pane_state: %{
            "last_event_seq" => event_seq,
            "stream_entries" => [
              %{
                "event_seq" => event_seq,
                "runtime_seq" => event_seq,
                "token" => token,
                "child_event_id" => child_event_id
              }
            ]
          },
          occurred_at_ms: event_seq * 10
        )
      end)

    assert {:ok, recovery_index} = RelationshipRecoveryIndex.build(records)

    assert {:ok, reconciled} =
             ChildSessionPanes.restore_recovered_relationships(live_state, recovery_index)

    assert [
             %{
               pane_state: %{
                 stream_entries: stream_entries
               }
             }
           ] = reconciled.working

    assert Enum.map(stream_entries, & &1.event_seq) == [1, 2, 3]

    assert Enum.map(stream_entries, & &1.token) == [
             "already-live",
             "journal-unseen-a",
             "journal-unseen-b"
           ]

    rendered = ChildSessionPanes.render(reconciled)
    assert [%{rendered_sequences: rendered_sequences}] = rendered.working

    assert Enum.map(rendered_sequences, & &1.event_seq) == [1, 2, 3]

    assert rendered_sequences
           |> Enum.map(& &1.child_event_id)
           |> Enum.frequencies() == %{
             "child-event:reconcile-live-1" => 1,
             "child-event:reconcile-live-2" => 1,
             "child-event:reconcile-live-3" => 1
           }
  end

  test "runtime replay surfaces a recoverable pane gap when cursor ranges are missing" do
    assert {:ok, recovery_index} =
             RelationshipRecoveryIndex.build([
               relationship_record(
                 event_seq: 2,
                 parent_call_id: "parent-cursor-gap-1",
                 child_id: "child-cursor-gap-a",
                 pane_id: "child-pane:cursor-gap-a",
                 runtime_source: "opencode",
                 transport: :sse,
                 external_ids: %{
                   "session_id" => "session-cursor-gap-a",
                   "childID" => "child-cursor-gap-a"
                 },
                 stream_cursor: %{event_seq: 2},
                 acknowledged_stream_cursor: %{:event_seq => 2, "event_id" => "evt-gap-a-2"},
                 pane_state: %{"last_event_seq" => 2},
                 occurred_at_ms: 20
               )
             ])

    assert {:ok, restored} =
             ChildSessionPanes.restore_recovered_relationships(
               ChildSessionPanes.new(),
               recovery_index
             )

    replayed =
      ChildSessionPanes.apply_event(restored, %{
        event_seq: 4,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-cursor-gap-1",
        runtime_source: "opencode",
        external_ids: %{"session_id" => "session-cursor-gap-a"},
        occurred_at_ms: 40,
        notification: %{
          "method" => "notifications/progress",
          "params" => %{"childID" => "child-cursor-gap-a", "seq" => 4, "token" => "after-gap"}
        }
      })

    assert [
             %{
               id: "child-pane:cursor-gap-a",
               child_id: "child-cursor-gap-a",
               pane_state: %{
                 replay_gap_error: %{
                   type: :recoverable_stream_gap,
                   pane_id: "child-pane:cursor-gap-a",
                   child_id: "child-cursor-gap-a",
                   expected_event_seq: 3,
                   received_event_seq: 4,
                   missing_event_seq_range: %{from: 3, to: 3},
                   missing_event_seqs: [3],
                   recovery: :resume_from_acknowledged_stream_cursor,
                   acknowledged_stream_cursor: %{:event_seq => 2, "event_id" => "evt-gap-a-2"}
                 },
                 stream_entries: [%{event_seq: 4, token: "after-gap"}]
               }
             }
           ] = replayed.working

    rendered = replayed |> ChildSessionPanes.render() |> Map.fetch!(:working) |> hd()

    assert rendered.replay_gap_error.type == :recoverable_stream_gap
    assert rendered.line =~ "gap=3..3"
  end

  test "focused_pane_state returns the currently focused child pane without rendering" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "query-focus-alpha",
               parent_call_id: "query-focus-parent-1",
               runtime_source: "opencode",
               transport: :sse,
               pane_state: %{title: "Alpha query", last_event_seq: 1},
               created_at_ms: 100,
               updated_at_ms: 100
             })

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "query-focus-bravo",
               parent_call_id: "query-focus-parent-1",
               runtime_source: "codex",
               transport: :stdio,
               external_ids: %{"native_session_id" => "query-focus-native-bravo"},
               pane_state: %{title: "Bravo query", last_event_seq: 2},
               created_at_ms: 200,
               updated_at_ms: 200
             })

    alpha_pane_id = "child-session:query-focus-alpha"

    assert {:ok,
            %{
              id: ^alpha_pane_id,
              kind: :child_session,
              status: :working,
              child_id: "query-focus-alpha",
              parent_call_id: "query-focus-parent-1",
              runtime_source: "opencode",
              transport: :sse,
              pane_state: %{
                title: "Alpha query",
                last_event_seq: 1,
                focused?: true
              }
            } = focused_pane} = ChildSessionPanes.focused_pane_state(state)

    refute Map.has_key?(focused_pane, :line)
    refute Map.has_key?(focused_pane, :stream_event_count)
    assert Enum.map(state.working, & &1.id) == [alpha_pane_id, "child-session:query-focus-bravo"]
  end

  defp relationship_record(attrs) do
    defaults = [
      event_seq: 1,
      event_type: :child_pane_registered,
      parent_call_id: "parent-default",
      child_id: "child-default",
      pane_id: "child-session:child-default",
      runtime_source: "ouroboros",
      transport: :stdio,
      external_ids: %{"childID" => "child-default"},
      stream_cursor: %{event_seq: 1, child_id: "child-default"},
      pane_state: %{},
      occurred_at_ms: 1
    ]

    struct!(RelationshipRecoveryRecord, Keyword.merge(defaults, attrs))
  end

  test "focused_pane_state reflects focus_session changes by child id and runtime metadata" do
    state = %{working: [], completed: [], focused: nil, open: []}

    state =
      [
        %{
          child_id: "query-change-alpha",
          parent_call_id: "query-change-parent-1",
          runtime_source: "opencode",
          transport: :sse,
          external_ids: %{"session_id" => "query-change-session-alpha"},
          pane_state: %{title: "Alpha"}
        },
        %{
          child_id: "query-change-bravo",
          parent_call_id: "query-change-parent-1",
          runtime_source: "codex",
          transport: :stdio,
          external_ids: %{"native_session_id" => "query-change-native-bravo"},
          pane_state: %{title: "Bravo"}
        }
      ]
      |> Enum.reduce(state, fn metadata, state ->
        assert {:ok, state} = ChildSessionPanes.register_child_pane(state, metadata)
        state
      end)

    assert {:ok, state} = ChildSessionPanes.focus_session(state, "query-change-native-bravo")

    assert {:ok,
            %{
              id: "child-session:query-change-bravo",
              child_id: "query-change-bravo",
              external_ids: %{"native_session_id" => "query-change-native-bravo"},
              pane_state: %{focused?: true, title: "Bravo"}
            }} = ChildSessionPanes.focused_pane_state(state)
  end

  test "focused_pane_state queries completed focused child panes" do
    pane_id = "child-session:query-completed-child"

    state = %{
      working: [],
      completed: [
        %{
          id: pane_id,
          kind: :child_session,
          status: :completed,
          child_id: "query-completed-child",
          parent_call_id: "query-completed-parent-1",
          runtime_source: "ouroboros",
          transport: :streamable_http,
          external_ids: %{"job_id" => "query-completed-job-1"},
          stream_cursor: %{event_seq: 7},
          pane_state: %{title: "Completed query", focused?: false},
          created_at_ms: 700,
          updated_at_ms: 800
        }
      ],
      focused: pane_id,
      open: [pane_id],
      child_pane_registry: %{"query-completed-child" => pane_id}
    }

    assert {:ok,
            %{
              id: ^pane_id,
              status: :completed,
              child_id: "query-completed-child",
              stream_cursor: %{event_seq: 7},
              pane_state: %{title: "Completed query", focused?: true}
            }} = ChildSessionPanes.focused_pane_state(state)
  end

  test "focused_pane_state rejects empty or stale focus without creating pane state" do
    empty_state = %{working: [], completed: [], focused: nil, open: []}

    assert {:error, :no_focused_child_session_pane} =
             ChildSessionPanes.focused_pane_state(empty_state)

    stale_state = %{
      working: [],
      completed: [],
      focused: "child-session:missing",
      open: ["child-session:missing"],
      child_pane_registry: %{"missing" => "child-session:missing"}
    }

    assert {:error, :focused_child_session_pane_not_found} =
             ChildSessionPanes.focused_pane_state(stale_state)

    assert stale_state.child_pane_registry == %{"missing" => "child-session:missing"}
    assert stale_state.open == ["child-session:missing"]
  end

  test "focus_session moves focus to an existing child pane by child_id without rendering or creating panes" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "focus-child-alpha",
               parent_call_id: "focus-parent-1",
               runtime_source: "opencode",
               transport: :sse,
               pane_state: %{title: "Alpha"},
               created_at_ms: 100,
               updated_at_ms: 100
             })

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "focus-child-bravo",
               parent_call_id: "focus-parent-1",
               runtime_source: "codex",
               transport: :stdio,
               pane_state: %{title: "Bravo"},
               created_at_ms: 200,
               updated_at_ms: 200
             })

    alpha_pane_id = "child-session:focus-child-alpha"
    bravo_pane_id = "child-session:focus-child-bravo"

    assert state.focused == alpha_pane_id
    assert Enum.map(state.working, & &1.id) == [alpha_pane_id, bravo_pane_id]

    assert {:ok, focused_state} = ChildSessionPanes.focus_session(state, " focus-child-bravo ")

    assert focused_state.focused == bravo_pane_id
    assert focused_state.open == [alpha_pane_id, bravo_pane_id]
    assert focused_state.child_pane_registry == state.child_pane_registry
    assert Enum.map(focused_state.working, & &1.id) == [alpha_pane_id, bravo_pane_id]
    assert focused_state.completed == []

    assert [
             %{id: ^alpha_pane_id, pane_state: %{focused?: false}},
             %{id: ^bravo_pane_id, pane_state: %{focused?: true}}
           ] = focused_state.working
  end

  test "focus_session moves focus to an existing completed pane by pane id" do
    pane_id = "child-session:focus-completed-child"

    state = %{
      working: [],
      completed: [
        %{
          id: pane_id,
          kind: :child_session,
          status: :completed,
          child_id: "focus-completed-child",
          parent_call_id: "focus-parent-completed-1",
          runtime_source: "ouroboros",
          transport: :streamable_http,
          external_ids: %{"job_id" => "focus-job-1"},
          stream_cursor: %{event_seq: 9},
          pane_state: %{open?: true, focused?: false, title: "Completed"},
          created_at_ms: 900,
          updated_at_ms: 990
        }
      ],
      focused: nil,
      open: [],
      child_pane_registry: %{"focus-completed-child" => pane_id}
    }

    assert {:ok, focused_state} = ChildSessionPanes.focus_session(state, pane_id)

    assert focused_state.focused == pane_id
    assert focused_state.open == [pane_id]
    assert focused_state.working == []

    assert [
             %{
               id: ^pane_id,
               child_id: "focus-completed-child",
               pane_state: %{focused?: true}
             }
           ] = focused_state.completed
  end

  test "focus_session resolves an existing child pane from selected runtime session metadata" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "focus-metadata-child",
               parent_call_id: "focus-parent-metadata-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "session_id" => "focus-runtime-session-1",
                 "thread_id" => "focus-runtime-thread-1"
               },
               pane_state: %{title: "Metadata selected"},
               created_at_ms: 300,
               updated_at_ms: 300
             })

    pane_id = "child-session:focus-metadata-child"

    assert {:ok, focused_state} =
             ChildSessionPanes.focus_session(state, "focus-runtime-session-1")

    assert focused_state.focused == pane_id
    assert focused_state.open == [pane_id]
    assert focused_state.child_pane_registry == %{"focus-metadata-child" => pane_id}

    assert [
             %{
               id: ^pane_id,
               child_id: "focus-metadata-child",
               pane_state: %{focused?: true}
             }
           ] = focused_state.working
  end

  test "focus_session rejects missing child panes without creating registry or open state" do
    state = %{
      working: [],
      completed: [],
      focused: "child-session:existing",
      open: ["child-session:existing"],
      child_pane_registry: %{"existing" => "child-session:existing"}
    }

    assert {:error, :child_session_pane_not_found} =
             ChildSessionPanes.focus_session(state, "missing-child")

    assert state.child_pane_registry == %{"existing" => "child-session:existing"}
    assert state.open == ["child-session:existing"]
    assert state.focused == "child-session:existing"
  end

  test "resolve_child_session returns an existing working session by child identifier" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "resolve-child-alpha",
               parent_call_id: "resolve-parent-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "session_id" => "resolve-runtime-session-alpha",
                 "thread_id" => "resolve-runtime-thread-alpha"
               },
               pane_state: %{title: "Resolve alpha"},
               created_at_ms: 100,
               updated_at_ms: 100
             })

    assert {:ok,
            %{
              kind: :existing_session,
              identifier: "resolve-child-alpha",
              child_id: "resolve-child-alpha",
              pane_id: "child-session:resolve-child-alpha",
              session: %{
                id: "child-session:resolve-child-alpha",
                child_id: "resolve-child-alpha",
                parent_call_id: "resolve-parent-1",
                runtime_source: "opencode",
                transport: :sse,
                external_ids: %{
                  "session_id" => "resolve-runtime-session-alpha",
                  "thread_id" => "resolve-runtime-thread-alpha"
                }
              }
            }} = ChildSessionPanes.resolve_child_session(state, " resolve-child-alpha ")

    assert state.open == ["child-session:resolve-child-alpha"]
    assert state.focused == "child-session:resolve-child-alpha"
  end

  test "resolve_child_session finds completed sessions by pane id and runtime metadata" do
    pane_id = "child-session:resolve-completed-child"

    state = %{
      working: [],
      completed: [
        %{
          id: pane_id,
          kind: :child_session,
          status: :completed,
          child_id: "resolve-completed-child",
          parent_call_id: "resolve-parent-completed-1",
          runtime_source: "codex",
          transport: :stdio,
          external_ids: %{
            "native_session_id" => "resolve-native-completed-1",
            "thread_id" => "resolve-thread-completed-1"
          },
          stream_cursor: %{event_seq: 12},
          pane_state: %{title: "Completed"},
          created_at_ms: 1_000,
          updated_at_ms: 1_200
        }
      ],
      focused: nil,
      open: [],
      child_pane_registry: %{"resolve-completed-child" => pane_id}
    }

    assert {:ok,
            %{
              kind: :existing_session,
              identifier: "child-session:resolve-completed-child",
              child_id: "resolve-completed-child",
              pane_id: ^pane_id,
              session: %{status: :completed, stream_cursor: %{event_seq: 12}}
            }} = ChildSessionPanes.resolve_child_session(state, pane_id)

    assert {:ok,
            %{
              kind: :existing_session,
              identifier: "resolve-native-completed-1",
              child_id: "resolve-completed-child",
              pane_id: ^pane_id,
              session: %{external_ids: %{"native_session_id" => "resolve-native-completed-1"}}
            }} = ChildSessionPanes.resolve_child_session(state, "resolve-native-completed-1")

    assert state.open == []
    assert state.focused == nil
  end

  test "resolve_child_session matches nested input session and call identifiers" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "resolve-nested-child",
               parent_call_id: "resolve-parent-nested-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "input" => %{
                   "sessionID" => "resolve-input-session-1",
                   "callID" => "resolve-input-call-1"
                 }
               },
               pane_state: %{title: "Nested runtime IDs"}
             })

    assert {:ok,
            %{
              kind: :existing_session,
              child_id: "resolve-nested-child",
              pane_id: "child-session:resolve-nested-child"
            }} = ChildSessionPanes.resolve_child_session(state, "resolve-input-session-1")

    assert {:ok,
            %{
              kind: :existing_session,
              child_id: "resolve-nested-child",
              pane_id: "child-session:resolve-nested-child"
            }} = ChildSessionPanes.resolve_child_session(state, "resolve-input-call-1")
  end

  test "resolve_child_session returns a create-open request when no session record exists" do
    state = %{
      working: [],
      completed: [],
      focused: nil,
      open: [],
      child_pane_registry: %{"resolve-missing-child" => "child-session:resolve-missing-child"}
    }

    assert {:ok,
            %{
              kind: :create_open_request,
              identifier: "resolve-missing-child",
              child_id: "resolve-missing-child",
              pane_id: "child-session:resolve-missing-child",
              request: %{
                action: :create_open,
                kind: :child_session_create_open_request,
                child_id: "resolve-missing-child",
                pane_id: "child-session:resolve-missing-child",
                selected_identifier: "resolve-missing-child",
                parent_call_id: "resolve-parent-create-1",
                runtime_source: "ouroboros",
                transport: :streamable_http,
                external_ids: %{
                  "job_id" => "resolve-job-create-1",
                  "childID" => "resolve-missing-child"
                },
                stream_cursor: %{event_seq: 0},
                pane_state: %{
                  open?: true,
                  focused?: true,
                  renderer: :default_child_session,
                  title: "Create this session"
                }
              }
            }} =
             ChildSessionPanes.resolve_child_session(state, "resolve-missing-child",
               parent_call_id: "resolve-parent-create-1",
               runtime_source: "ouroboros",
               transport: :streamable_http,
               external_ids: %{"job_id" => "resolve-job-create-1"},
               stream_cursor: %{event_seq: 0},
               pane_state: %{title: "Create this session"}
             )

    assert state.child_pane_registry == %{
             "resolve-missing-child" => "child-session:resolve-missing-child"
           }

    assert state.open == []
    assert state.focused == nil
  end

  test "resolve_child_session converts a missing pane id into a create-open child request" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok,
            %{
              kind: :create_open_request,
              identifier: "child-session:resolve-new-pane-id",
              child_id: "resolve-new-pane-id",
              pane_id: "child-session:resolve-new-pane-id",
              request: %{
                child_id: "resolve-new-pane-id",
                pane_id: "child-session:resolve-new-pane-id",
                selected_identifier: "child-session:resolve-new-pane-id",
                external_ids: %{"childID" => "resolve-new-pane-id"}
              }
            }} =
             ChildSessionPanes.resolve_child_session(
               state,
               " child-session:resolve-new-pane-id "
             )
  end

  test "resolve_child_session rejects blank identifiers and invalid state without creating requests" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:error, :invalid_child_session_identifier} =
             ChildSessionPanes.resolve_child_session(state, "  ")

    assert {:error, :invalid_child_session_identifier} =
             ChildSessionPanes.resolve_child_session(state, " child-session: ")

    assert {:error, :invalid_child_session_identifier} =
             ChildSessionPanes.resolve_child_session(state, 123)

    assert {:error, :invalid_child_session_state} =
             ChildSessionPanes.resolve_child_session(%{working: []}, "missing-child")
  end

  test "open_resolved_child_session opens a new child pane when no pane is active" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok, resolution} =
             ChildSessionPanes.resolve_child_session(state, "open-new-session-1",
               parent_call_id: "open-parent-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "session_id" => "open-runtime-session-1",
                 "thread_id" => "open-runtime-thread-1"
               },
               stream_cursor: %{"event_id" => "evt-open-1", event_seq: 0},
               pane_state: %{title: "Open resolved session"}
             )

    assert %{
             kind: :create_open_request,
             child_id: "open-new-session-1",
             pane_id: "child-session:open-new-session-1"
           } = resolution

    assert {:ok, opened_state} =
             ChildSessionPanes.open_resolved_child_session(state, resolution)

    pane_id = "child-session:open-new-session-1"

    assert opened_state.focused == pane_id
    assert opened_state.open == [pane_id]
    assert opened_state.completed == []
    assert opened_state.child_pane_registry == %{"open-new-session-1" => pane_id}

    assert [
             %{
               id: ^pane_id,
               kind: :child_session,
               status: :working,
               child_id: "open-new-session-1",
               parent_call_id: "open-parent-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "session_id" => "open-runtime-session-1",
                 "thread_id" => "open-runtime-thread-1",
                 "childID" => "open-new-session-1"
               },
               stream_cursor: %{
                 "event_id" => "evt-open-1",
                 event_seq: 0,
                 transport: :sse,
                 child_id: "open-new-session-1"
               },
               pane_state: %{
                 open?: true,
                 focused?: true,
                 renderer: :default_child_session,
                 title: "Open resolved session"
               }
             }
           ] = opened_state.working
  end

  test "open_resolved_child_session focuses an existing resolved child pane without duplicating it" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "open-existing-child",
               parent_call_id: "open-parent-existing-1",
               runtime_source: "codex",
               transport: :stdio,
               external_ids: %{"native_session_id" => "open-native-existing-1"},
               pane_state: %{title: "Existing"}
             })

    state = %{state | focused: nil, open: []}

    assert {:ok, resolution} =
             ChildSessionPanes.resolve_child_session(state, "open-native-existing-1")

    assert {:ok, opened_state} =
             ChildSessionPanes.open_resolved_child_session(state, resolution)

    pane_id = "child-session:open-existing-child"

    assert opened_state.focused == pane_id
    assert opened_state.open == [pane_id]
    assert Enum.map(opened_state.working, & &1.id) == [pane_id]
    assert opened_state.child_pane_registry == %{"open-existing-child" => pane_id}
    assert [%{pane_state: %{focused?: true}}] = opened_state.working
  end

  test "open_child_session reuses and activates an existing pane for matching session metadata" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "open-session-existing-child",
               parent_call_id: "open-session-parent-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{"session_id" => "open-session-runtime-1"},
               pane_state: %{title: "Existing session"}
             })

    state = %{state | focused: nil, open: []}

    assert {:ok, opened_state} =
             ChildSessionPanes.open_child_session(state, "open-session-new-child",
               parent_call_id: "open-session-parent-2",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{"session_id" => "open-session-runtime-1"},
               pane_state: %{title: "Should not create duplicate"}
             )

    pane_id = "child-session:open-session-existing-child"

    assert opened_state.focused == pane_id
    assert opened_state.open == [pane_id]
    assert opened_state.child_pane_registry == %{"open-session-existing-child" => pane_id}
    assert Enum.map(opened_state.working, & &1.id) == [pane_id]

    assert [
             %{
               id: ^pane_id,
               child_id: "open-session-existing-child",
               external_ids: %{
                 "session_id" => "open-session-runtime-1",
                 "childID" => "open-session-existing-child"
               },
               pane_state: %{focused?: true, title: "Existing session"}
             }
           ] = opened_state.working
  end

  test "open_child_session resolves and opens a missing selected session identifier" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok, opened_state} =
             ChildSessionPanes.open_child_session(state, "open-wrapper-child",
               parent_call_id: "open-wrapper-parent-1",
               runtime_source: "ouroboros",
               transport: :streamable_http,
               external_ids: %{"job_id" => "open-wrapper-job-1"},
               pane_state: %{title: "Wrapper open"}
             )

    pane_id = "child-session:open-wrapper-child"

    assert opened_state.focused == pane_id
    assert opened_state.open == [pane_id]
    assert opened_state.child_pane_registry == %{"open-wrapper-child" => pane_id}

    assert [%{id: ^pane_id, pane_state: %{focused?: true, title: "Wrapper open"}}] =
             opened_state.working
  end

  test "registers a child session pane from metadata with a unique pane identifier" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: " child-metadata-1 ",
               parent_call_id: "parent-metadata-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "session_id" => "session-metadata-1",
                 "thread_id" => "thread-metadata-1"
               },
               stream_cursor: %{"event_id" => "evt-metadata-1", "offset" => 24},
               pane_state: %{renderer: :trusted_plugin_renderer, title: "Inspect failing test"},
               created_at_ms: 1_000,
               updated_at_ms: 1_100
             })

    pane_id = "child-session:child-metadata-1"

    assert state.child_pane_registry == %{"child-metadata-1" => pane_id}
    assert state.focused == pane_id
    assert state.open == [pane_id]
    assert state.completed == []

    assert [
             %{
               id: ^pane_id,
               kind: :child_session,
               status: :working,
               child_id: "child-metadata-1",
               parent_call_id: "parent-metadata-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "session_id" => "session-metadata-1",
                 "thread_id" => "thread-metadata-1",
                 "childID" => "child-metadata-1"
               },
               stream_cursor: %{
                 "event_id" => "evt-metadata-1",
                 "offset" => 24,
                 transport: :sse,
                 child_id: "child-metadata-1"
               },
               pane_state: %{
                 open?: true,
                 focused?: false,
                 renderer: :trusted_plugin_renderer,
                 title: "Inspect failing test"
               },
               created_at_ms: 1_000,
               updated_at_ms: 1_100
             }
           ] = state.working
  end

  test "metadata registration reuses existing child panes and keeps identifiers unique" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "child-metadata-a",
               parent_call_id: "parent-metadata-1",
               runtime_source: "ouroboros",
               transport: "streamable_http",
               external_ids: %{"job_id" => "job-a"},
               stream_cursor: %{event_seq: 1},
               pane_state: %{last_event_seq: 1},
               created_at_ms: 100,
               updated_at_ms: 100
             })

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "child-metadata-b",
               parent_call_id: "parent-metadata-1",
               runtime_source: "ouroboros",
               transport: "streamable_http",
               external_ids: %{"job_id" => "job-b"},
               stream_cursor: %{event_seq: 2},
               pane_state: %{last_event_seq: 2},
               created_at_ms: 200,
               updated_at_ms: 200
             })

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "child-metadata-a",
               parent_call_id: "parent-metadata-1",
               runtime_source: "ouroboros",
               transport: "streamable_http",
               external_ids: %{"execution_id" => "execution-a"},
               stream_cursor: %{event_seq: 3},
               pane_state: %{last_event_seq: 3},
               updated_at_ms: 300
             })

    pane_a = "child-session:child-metadata-a"
    pane_b = "child-session:child-metadata-b"

    assert state.child_pane_registry == %{
             "child-metadata-a" => pane_a,
             "child-metadata-b" => pane_b
           }

    assert state.open == [pane_a, pane_b]
    assert state.focused == pane_a
    assert state.child_pane_registry |> Map.values() |> Enum.uniq() |> length() == 2

    assert [
             %{
               id: ^pane_a,
               child_id: "child-metadata-a",
               external_ids: %{
                 "job_id" => "job-a",
                 "execution_id" => "execution-a",
                 "childID" => "child-metadata-a"
               },
               stream_cursor: %{
                 event_seq: 3,
                 transport: :streamable_http,
                 child_id: "child-metadata-a"
               },
               pane_state: %{last_event_seq: 3},
               created_at_ms: 100,
               updated_at_ms: 300
             },
             %{
               id: ^pane_b,
               child_id: "child-metadata-b",
               stream_cursor: %{
                 event_seq: 2,
                 transport: :streamable_http,
                 child_id: "child-metadata-b"
               },
               pane_state: %{last_event_seq: 2},
               created_at_ms: 200,
               updated_at_ms: 200
             }
           ] = state.working
  end

  test "metadata registration reuses an existing pane for a matching runtime session identifier" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "fallback:session_id:metadata-session-reuse-1",
               parent_call_id: "metadata-session-parent-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "session_id" => "metadata-session-reuse-1",
                 "fallback_child_id" => "fallback:session_id:metadata-session-reuse-1",
                 "fallback_child_id_source" => "session_id"
               },
               stream_cursor: %{event_seq: 1},
               pane_state: %{title: "Fallback session", last_event_seq: 1},
               created_at_ms: 100,
               updated_at_ms: 100
             })

    fallback_pane_id = "child-session:fallback:session_id:metadata-session-reuse-1"

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "metadata-real-child-1",
               parent_call_id: "metadata-session-parent-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{"session_id" => "metadata-session-reuse-1"},
               stream_cursor: %{event_seq: 2},
               pane_state: %{title: "Real child session", last_event_seq: 2},
               updated_at_ms: 200
             })

    assert state.child_pane_registry == %{
             "fallback:session_id:metadata-session-reuse-1" => fallback_pane_id,
             "metadata-real-child-1" => fallback_pane_id
           }

    assert state.focused == fallback_pane_id
    assert state.open == [fallback_pane_id]
    assert [] = state.completed

    assert [
             %{
               id: ^fallback_pane_id,
               child_id: "metadata-real-child-1",
               external_ids: %{
                 "session_id" => "metadata-session-reuse-1",
                 "childID" => "metadata-real-child-1",
                 "fallback_child_id" => "fallback:session_id:metadata-session-reuse-1",
                 "fallback_child_id_source" => "session_id"
               },
               stream_cursor: %{
                 event_seq: 2,
                 transport: :sse,
                 child_id: "metadata-real-child-1"
               },
               pane_state: %{title: "Real child session", last_event_seq: 2},
               created_at_ms: 100,
               updated_at_ms: 200
             }
           ] = state.working
  end

  test "metadata registration retains multiple sibling child panes for the same parent" do
    state = %{working: [], completed: [], focused: nil, open: []}

    state =
      Enum.reduce(["alpha", "bravo", "charlie"], state, fn child_suffix, state ->
        assert {:ok, state} =
                 ChildSessionPanes.register_child_pane(state, %{
                   child_id: "child-sibling-#{child_suffix}",
                   parent_call_id: "parent-siblings-1",
                   runtime_source: "opencode",
                   transport: :sse,
                   external_ids: %{
                     "session_id" => "session-siblings-1",
                     "thread_id" => "thread-sibling-#{child_suffix}"
                   },
                   stream_cursor: %{"event_id" => "evt-sibling-#{child_suffix}"},
                   pane_state: %{
                     title: "Sibling #{child_suffix}",
                     last_event_seq: String.length(child_suffix)
                   },
                   created_at_ms: String.length(child_suffix) * 100,
                   updated_at_ms: String.length(child_suffix) * 100
                 })

        state
      end)

    pane_alpha = "child-session:child-sibling-alpha"
    pane_bravo = "child-session:child-sibling-bravo"
    pane_charlie = "child-session:child-sibling-charlie"

    assert state.focused == pane_alpha
    assert state.open == [pane_alpha, pane_bravo, pane_charlie]

    assert state.child_pane_registry == %{
             "child-sibling-alpha" => pane_alpha,
             "child-sibling-bravo" => pane_bravo,
             "child-sibling-charlie" => pane_charlie
           }

    assert Enum.map(state.working, & &1.id) == [pane_alpha, pane_bravo, pane_charlie]
    assert Enum.map(state.working, & &1.parent_call_id) == List.duplicate("parent-siblings-1", 3)

    assert Enum.map(state.working, & &1.child_id) == [
             "child-sibling-alpha",
             "child-sibling-bravo",
             "child-sibling-charlie"
           ]

    assert state.completed == []
    assert state.child_pane_registry |> Map.values() |> Enum.uniq() |> length() == 3
  end

  test "multi-pane metadata remains isolated by pane identifier across registrations" do
    state = %{working: [], completed: [], focused: nil, open: []}

    panes = [
      %{
        child_id: "child-metadata-isolated-alpha",
        parent_call_id: "parent-isolated-1",
        runtime_source: "opencode",
        transport: :sse,
        external_ids: %{
          "session_id" => "session-alpha",
          "thread_id" => "thread-alpha"
        },
        stream_cursor: %{"event_id" => "evt-alpha", "offset" => 10},
        pane_state: %{
          renderer: :alpha_renderer,
          title: "Alpha pane",
          last_event_seq: 1,
          focus_group: :left
        },
        created_at_ms: 1_000,
        updated_at_ms: 1_010
      },
      %{
        child_id: "child-metadata-isolated-bravo",
        parent_call_id: "parent-isolated-1",
        runtime_source: "codex",
        transport: :stdio,
        external_ids: %{
          "native_session_id" => "native-bravo",
          "thread_id" => "thread-bravo"
        },
        stream_cursor: %{byte_offset: 20, event_seq: 2},
        pane_state: %{
          renderer: :bravo_renderer,
          title: "Bravo pane",
          last_event_seq: 2,
          focus_group: :center
        },
        created_at_ms: 2_000,
        updated_at_ms: 2_020
      },
      %{
        child_id: "child-metadata-isolated-charlie",
        parent_call_id: "parent-isolated-2",
        runtime_source: "ouroboros",
        transport: :streamable_http,
        external_ids: %{
          "job_id" => "job-charlie",
          "execution_id" => "execution-charlie"
        },
        stream_cursor: %{"cursor" => "http-charlie", event_seq: 3},
        pane_state: %{
          renderer: :charlie_renderer,
          title: "Charlie pane",
          last_event_seq: 3,
          focus_group: :right
        },
        created_at_ms: 3_000,
        updated_at_ms: 3_030
      }
    ]

    state =
      Enum.reduce(panes, state, fn metadata, state ->
        assert {:ok, state} = ChildSessionPanes.register_child_pane(state, metadata)
        state
      end)

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "child-metadata-isolated-bravo",
               parent_call_id: "parent-isolated-1",
               runtime_source: "codex",
               transport: :stdio,
               external_ids: %{"execution_id" => "execution-bravo"},
               stream_cursor: %{byte_offset: 42, event_seq: 4},
               pane_state: %{last_event_seq: 4, title: "Bravo pane updated"},
               updated_at_ms: 4_040
             })

    pane_alpha = "child-session:child-metadata-isolated-alpha"
    pane_bravo = "child-session:child-metadata-isolated-bravo"
    pane_charlie = "child-session:child-metadata-isolated-charlie"
    panes_by_id = Map.new(state.working, &{&1.id, &1})

    assert state.child_pane_registry == %{
             "child-metadata-isolated-alpha" => pane_alpha,
             "child-metadata-isolated-bravo" => pane_bravo,
             "child-metadata-isolated-charlie" => pane_charlie
           }

    assert state.open == [pane_alpha, pane_bravo, pane_charlie]
    assert state.focused == pane_alpha
    assert map_size(panes_by_id) == 3

    assert %{
             parent_call_id: "parent-isolated-1",
             runtime_source: "opencode",
             transport: :sse,
             external_ids: %{
               "session_id" => "session-alpha",
               "thread_id" => "thread-alpha",
               "childID" => "child-metadata-isolated-alpha"
             },
             stream_cursor: %{
               "event_id" => "evt-alpha",
               "offset" => 10,
               transport: :sse,
               child_id: "child-metadata-isolated-alpha"
             },
             pane_state: %{
               renderer: :alpha_renderer,
               title: "Alpha pane",
               last_event_seq: 1,
               focus_group: :left
             },
             created_at_ms: 1_000,
             updated_at_ms: 1_010
           } = Map.fetch!(panes_by_id, pane_alpha)

    assert %{
             parent_call_id: "parent-isolated-1",
             runtime_source: "codex",
             transport: :stdio,
             external_ids: %{
               "native_session_id" => "native-bravo",
               "thread_id" => "thread-bravo",
               "execution_id" => "execution-bravo",
               "childID" => "child-metadata-isolated-bravo"
             },
             stream_cursor: %{
               byte_offset: 42,
               event_seq: 4,
               transport: :stdio,
               child_id: "child-metadata-isolated-bravo"
             },
             pane_state: %{
               renderer: :bravo_renderer,
               title: "Bravo pane updated",
               last_event_seq: 4,
               focus_group: :center
             },
             created_at_ms: 2_000,
             updated_at_ms: 4_040
           } = Map.fetch!(panes_by_id, pane_bravo)

    assert %{
             parent_call_id: "parent-isolated-2",
             runtime_source: "ouroboros",
             transport: :streamable_http,
             external_ids: %{
               "job_id" => "job-charlie",
               "execution_id" => "execution-charlie",
               "childID" => "child-metadata-isolated-charlie"
             },
             stream_cursor: %{
               "cursor" => "http-charlie",
               event_seq: 3,
               transport: :streamable_http,
               child_id: "child-metadata-isolated-charlie"
             },
             pane_state: %{
               renderer: :charlie_renderer,
               title: "Charlie pane",
               last_event_seq: 3,
               focus_group: :right
             },
             created_at_ms: 3_000,
             updated_at_ms: 3_030
           } = Map.fetch!(panes_by_id, pane_charlie)
  end

  test "renders each registered child session as exactly one stable pane" do
    state = %{working: [], completed: [], focused: nil, open: []}

    state =
      [
        %{
          child_id: "render-child-alpha",
          parent_call_id: "render-parent-1",
          runtime_source: "opencode",
          transport: :sse,
          external_ids: %{"session_id" => "render-session-alpha"},
          stream_cursor: %{event_seq: 1},
          pane_state: %{title: "Alpha", last_event_seq: 1},
          created_at_ms: 100,
          updated_at_ms: 100
        },
        %{
          child_id: "render-child-bravo",
          parent_call_id: "render-parent-1",
          runtime_source: "codex",
          transport: :stdio,
          external_ids: %{"thread_id" => "render-thread-bravo"},
          stream_cursor: %{event_seq: 2},
          pane_state: %{
            title: "Bravo",
            last_event_seq: 2,
            stream_entries: [%{event_seq: 2, token: "first"}]
          },
          created_at_ms: 200,
          updated_at_ms: 200
        },
        %{
          child_id: "render-child-charlie",
          parent_call_id: "render-parent-2",
          runtime_source: "ouroboros",
          transport: :streamable_http,
          external_ids: %{"job_id" => "render-job-charlie"},
          stream_cursor: %{event_seq: 3},
          pane_state: %{title: "Charlie", last_event_seq: 3},
          created_at_ms: 300,
          updated_at_ms: 300
        }
      ]
      |> Enum.reduce(state, fn metadata, state ->
        assert {:ok, state} = ChildSessionPanes.register_child_pane(state, metadata)
        state
      end)

    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(state, %{
               child_id: "render-child-bravo",
               parent_call_id: "render-parent-1",
               runtime_source: "codex",
               transport: :stdio,
               external_ids: %{"execution_id" => "render-execution-bravo"},
               stream_cursor: %{event_seq: 4},
               pane_state: %{title: "Bravo updated", last_event_seq: 4},
               updated_at_ms: 400
             })

    rendered = ChildSessionPanes.render(state)

    pane_alpha = "child-session:render-child-alpha"
    pane_bravo = "child-session:render-child-bravo"
    pane_charlie = "child-session:render-child-charlie"

    assert rendered.id == :child_session_panes
    assert rendered.empty? == false
    assert rendered.focused == pane_alpha
    assert rendered.open == [pane_alpha, pane_bravo, pane_charlie]

    assert rendered.child_pane_registry == %{
             "render-child-alpha" => pane_alpha,
             "render-child-bravo" => pane_bravo,
             "render-child-charlie" => pane_charlie
           }

    rendered_ids = Enum.map(rendered.working, & &1.id)
    rendered_child_ids = Enum.map(rendered.working, & &1.child_id)

    assert rendered_ids == [pane_alpha, pane_bravo, pane_charlie]
    assert Enum.uniq(rendered_ids) == rendered_ids

    assert Enum.sort(rendered_child_ids) == [
             "render-child-alpha",
             "render-child-bravo",
             "render-child-charlie"
           ]

    assert rendered.completed == []
    assert length(rendered.working) == map_size(rendered.child_pane_registry)

    assert %{
             id: ^pane_bravo,
             title: "Bravo updated",
             status: "working",
             child_id: "render-child-bravo",
             parent_call_id: "render-parent-1",
             runtime_source: "codex",
             transport: "stdio",
             stream_cursor: %{
               event_seq: 4,
               transport: :stdio,
               child_id: "render-child-bravo"
             },
             external_ids: %{
               "thread_id" => "render-thread-bravo",
               "execution_id" => "render-execution-bravo",
               "childID" => "render-child-bravo"
             },
             stream_event_count: 1,
             last_event_seq: 4,
             line:
               "[working] child=render-child-bravo pane=child-session:render-child-bravo parent=render-parent-1 runtime=codex transport=stdio seq=4 events=1"
           } = Enum.find(rendered.working, &(&1.id == pane_bravo))
  end

  test "creates a working child session pane from a stdio MCP event with childID" do
    state = %{working: [], completed: [], focused: nil, open: []}

    event = %{
      event_seq: 7,
      type: :parent_call_event,
      transport: :stdio,
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-1"},
      occurred_at_ms: 1_715_000_000_000,
      notification: %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"childID" => "child-1", "seq" => 1}
      }
    }

    assert %{
             working: [
               %{
                 id: "child-session:child-1",
                 kind: :child_session,
                 status: :working,
                 child_id: "child-1",
                 parent_call_id: "parent-1",
                 runtime_source: "synthetic",
                 transport: :stdio,
                 external_ids: %{"session_id" => "session-1", "childID" => "child-1"},
                 stream_cursor: %{transport: :stdio, event_seq: 7, child_id: "child-1"},
                 pane_state: %{
                   open?: true,
                   focused?: false,
                   renderer: :default_child_session,
                   last_event_seq: 7
                 },
                 created_at_ms: 1_715_000_000_000,
                 updated_at_ms: 1_715_000_000_000
               }
             ],
             completed: [],
             focused: "child-session:child-1",
             open: ["child-session:child-1"]
           } = ChildSessionPanes.apply_event(state, event)
  end

  test "updates an existing child pane cursor without duplicating it" do
    state =
      ChildSessionPanes.apply_event(%{working: [], completed: [], focused: nil, open: []}, %{
        event_seq: 1,
        type: :parent_call_event,
        transport: :stdio,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{},
        occurred_at_ms: 100,
        notification: %{"params" => %{"childID" => "child-1"}}
      })

    state =
      ChildSessionPanes.apply_event(state, %{
        event_seq: 2,
        type: :parent_call_event,
        transport: :stdio,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{"thread_id" => "thread-1"},
        occurred_at_ms: 200,
        notification: %{"params" => %{"childID" => "child-1"}}
      })

    assert [
             %{
               id: "child-session:child-1",
               stream_cursor: %{event_seq: 2},
               external_ids: %{"childID" => "child-1", "thread_id" => "thread-1"},
               pane_state: %{last_event_seq: 2},
               created_at_ms: 100,
               updated_at_ms: 200
             }
           ] = state.working

    assert state.open == ["child-session:child-1"]
  end

  test "child pane registry creates one distinct pane key per new childID" do
    initial_state = %{working: [], completed: [], focused: nil, open: []}

    event = fn child_id, event_seq ->
      %{
        event_seq: event_seq,
        type: :parent_call_event,
        transport: :stdio,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-1"},
        occurred_at_ms: event_seq * 100,
        notification: %{"params" => %{"childID" => child_id, "seq" => event_seq}}
      }
    end

    state =
      initial_state
      |> ChildSessionPanes.apply_event(event.("child-1", 1))
      |> ChildSessionPanes.apply_event(event.("child-2", 2))
      |> ChildSessionPanes.apply_event(event.("child-1", 3))

    assert state.child_pane_registry == %{
             "child-1" => "child-session:child-1",
             "child-2" => "child-session:child-2"
           }

    assert ["child-session:child-1", "child-session:child-2"] = state.open

    assert [
             %{id: "child-session:child-1", child_id: "child-1", stream_cursor: %{event_seq: 3}},
             %{id: "child-session:child-2", child_id: "child-2", stream_cursor: %{event_seq: 2}}
           ] = state.working

    assert map_size(state.child_pane_registry) == 2
    assert state.child_pane_registry |> Map.values() |> Enum.uniq() |> length() == 2
  end

  test "repeated child creation events identify the existing pane without duplicates" do
    creation_event = fn event_seq, occurred_at_ms ->
      %{
        event_seq: event_seq,
        type: :parent_call_started,
        transport: :stdio,
        parent_call_id: "parent-creation-1",
        runtime_source: "opencode",
        external_ids: %{"session_id" => "session-creation-1"},
        occurred_at_ms: occurred_at_ms,
        params: %{"childID" => "child-creation-1"}
      }
    end

    state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ChildSessionPanes.apply_event(creation_event.(1, 100))
      |> ChildSessionPanes.apply_event(creation_event.(2, 200))
      |> ChildSessionPanes.apply_event(creation_event.(3, 300))

    pane_id = ChildSessionPanes.child_pane_key(state.child_pane_registry, "child-creation-1")

    assert pane_id == "child-session:child-creation-1"
    assert state.child_pane_registry == %{"child-creation-1" => pane_id}
    assert state.open == [pane_id]
    assert state.focused == pane_id
    assert [] = state.completed

    assert [
             %{
               id: ^pane_id,
               child_id: "child-creation-1",
               status: :working,
               stream_cursor: %{event_seq: 3},
               pane_state: %{last_event_seq: 3},
               created_at_ms: 100,
               updated_at_ms: 300
             }
           ] = state.working
  end

  test "maps fallback runtime IDs from child creation events into child pane identifiers" do
    state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ChildSessionPanes.apply_event(%{
        event_seq: 4,
        type: :parent_call_started,
        transport: :streamable_http,
        parent_call_id: "parent-fallback-create-1",
        runtime_source: "opencode",
        external_ids: %{
          "input" => %{
            "sessionID" => "input-session-create-1",
            "callID" => "input-call-create-1"
          }
        },
        occurred_at_ms: 400,
        method: "agent/session/create",
        params: %{"task" => "inspect the failing smoke test"}
      })

    fallback_id = "fallback:input_session_id:input-session-create-1"
    pane_id = "child-session:" <> fallback_id

    assert state.child_pane_registry == %{fallback_id => pane_id}
    assert state.focused == pane_id
    assert state.open == [pane_id]
    assert [] = state.completed

    assert [
             %{
               id: ^pane_id,
               kind: :child_session,
               status: :working,
               child_id: ^fallback_id,
               parent_call_id: "parent-fallback-create-1",
               runtime_source: "opencode",
               transport: :streamable_http,
               external_ids: %{
                 "input" => %{
                   "sessionID" => "input-session-create-1",
                   "callID" => "input-call-create-1"
                 },
                 "child_id" => ^fallback_id,
                 "fallback_child_id" => ^fallback_id,
                 "fallback_child_id_source" => "input_session_id"
               },
               stream_cursor: %{
                 transport: :streamable_http,
                 event_seq: 4,
                 child_id: ^fallback_id
               },
               pane_state: %{last_event_seq: 4},
               created_at_ms: 400,
               updated_at_ms: 400
             }
           ] = state.working
  end

  test "missing childID creation events create distinct panes when fallback runtime IDs differ" do
    creation_event = fn event_seq, job_id, call_id ->
      %{
        event_seq: event_seq,
        type: :parent_call_started,
        transport: :streamable_http,
        parent_call_id: "parent-fallback-distinct-#{event_seq}",
        runtime_source: "ouroboros",
        external_ids: %{
          "job_id" => job_id,
          "session_id" => "shared-runtime-session",
          "call_id" => call_id
        },
        occurred_at_ms: event_seq * 100,
        method: "agent/session/create",
        params: %{"task" => "start child session #{event_seq}"}
      }
    end

    state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ChildSessionPanes.apply_event(creation_event.(1, "job-child-a", "call-child-a"))
      |> ChildSessionPanes.apply_event(creation_event.(2, "job-child-b", "call-child-b"))

    fallback_a = "fallback:job_id:job-child-a"
    fallback_b = "fallback:job_id:job-child-b"
    pane_a = "child-session:" <> fallback_a
    pane_b = "child-session:" <> fallback_b

    assert state.child_pane_registry == %{fallback_a => pane_a, fallback_b => pane_b}
    assert state.open == [pane_a, pane_b]
    assert state.focused == pane_a
    assert [] = state.completed

    assert [
             %{
               id: ^pane_a,
               child_id: ^fallback_a,
               parent_call_id: "parent-fallback-distinct-1",
               external_ids: %{
                 "job_id" => "job-child-a",
                 "session_id" => "shared-runtime-session",
                 "call_id" => "call-child-a",
                 "fallback_child_id" => ^fallback_a,
                 "fallback_child_id_source" => "job_id"
               },
               stream_cursor: %{event_seq: 1, child_id: ^fallback_a}
             },
             %{
               id: ^pane_b,
               child_id: ^fallback_b,
               parent_call_id: "parent-fallback-distinct-2",
               external_ids: %{
                 "job_id" => "job-child-b",
                 "session_id" => "shared-runtime-session",
                 "call_id" => "call-child-b",
                 "fallback_child_id" => ^fallback_b,
                 "fallback_child_id_source" => "job_id"
               },
               stream_cursor: %{event_seq: 2, child_id: ^fallback_b}
             }
           ] = state.working
  end

  test "maps streamable HTTP child events to stable child pane identities" do
    state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ChildSessionPanes.apply_event(%{
        event_seq: 10,
        type: :parent_call_event,
        transport: :streamable_http,
        parent_call_id: "parent-http-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-http-1"},
        occurred_at_ms: 1_000,
        notification: %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{"childID" => "child-http-1", "seq" => 1}
        }
      })
      |> ChildSessionPanes.apply_event(%{
        event_seq: 11,
        type: :parent_call_result,
        transport: :streamable_http,
        parent_call_id: "parent-http-1",
        runtime_source: "synthetic",
        external_ids: %{"thread_id" => "thread-http-1"},
        occurred_at_ms: 1_100,
        result: %{"childID" => "child-http-1", "seq" => 2, "ok" => true}
      })

    pane_id = "child-session:child-http-1"

    assert state.child_pane_registry == %{"child-http-1" => pane_id}
    assert state.focused == pane_id
    assert state.open == [pane_id]

    assert [
             %{
               id: ^pane_id,
               child_id: "child-http-1",
               parent_call_id: "parent-http-1",
               transport: :streamable_http,
               external_ids: %{
                 "session_id" => "session-http-1",
                 "thread_id" => "thread-http-1",
                 "childID" => "child-http-1"
               },
               stream_cursor: %{
                 transport: :streamable_http,
                 event_seq: 11,
                 child_id: "child-http-1"
               },
               pane_state: %{last_event_seq: 11},
               created_at_ms: 1_000,
               updated_at_ms: 1_100
             }
           ] = state.working
  end

  test "maps SSE child events to stable child pane identities from raw event data" do
    state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ChildSessionPanes.apply_event(%{
        event_seq: 20,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-sse-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-sse-1"},
        occurred_at_ms: 2_000,
        raw_event: %{
          "event" => "message",
          "data" => %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{"childID" => "child-sse-1", "seq" => 1}
          }
        }
      })
      |> ChildSessionPanes.apply_event(%{
        event_seq: 21,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-sse-1",
        runtime_source: "synthetic",
        external_ids: %{"thread_id" => "thread-sse-1"},
        occurred_at_ms: 2_100,
        notification: %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{"childID" => "child-sse-1", "seq" => 2}
        }
      })

    pane_id = "child-session:child-sse-1"

    assert state.child_pane_registry == %{"child-sse-1" => pane_id}
    assert state.open == [pane_id]

    assert [
             %{
               id: ^pane_id,
               child_id: "child-sse-1",
               transport: :sse,
               external_ids: %{
                 "session_id" => "session-sse-1",
                 "thread_id" => "thread-sse-1",
                 "childID" => "child-sse-1"
               },
               stream_cursor: %{transport: :sse, event_seq: 21, child_id: "child-sse-1"},
               created_at_ms: 2_000,
               updated_at_ms: 2_100
             }
           ] = state.working
  end

  test "maps SSE child/session identity aliases to the same stable pane key" do
    event = fn field, value, seq ->
      %{
        event_seq: seq,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-sse-alias-1",
        runtime_source: "opencode",
        external_ids: %{"session_id" => "runtime-session-sse-alias-1"},
        occurred_at_ms: seq * 100,
        raw_event: %{
          "event" => "message",
          "data" => %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{field => value, "seq" => seq}
          }
        }
      }
    end

    state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ChildSessionPanes.apply_event(event.("childId", " child-sse-alias-1 ", 30))
      |> ChildSessionPanes.apply_event(event.("child_session_id", "child-sse-alias-1", 31))
      |> ChildSessionPanes.apply_event(event.("agentSessionID", "child-sse-alias-1", 32))

    pane_id = "child-session:child-sse-alias-1"

    assert state.child_pane_registry == %{"child-sse-alias-1" => pane_id}
    assert state.open == [pane_id]

    assert [
             %{
               id: ^pane_id,
               child_id: "child-sse-alias-1",
               transport: :sse,
               stream_cursor: %{transport: :sse, event_seq: 32, child_id: "child-sse-alias-1"},
               pane_state: %{last_event_seq: 32},
               created_at_ms: 3_000,
               updated_at_ms: 3_200
             }
           ] = state.working
  end

  test "OpenCode child-session mapping retains child, job, session, and execution IDs" do
    state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ChildSessionPanes.apply_event(%{
        event_seq: 50,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-opencode-identity-1",
        runtime_source: "opencode",
        external_ids: %{},
        occurred_at_ms: 5_000,
        raw_event: %{
          "event" => "message",
          "data" => %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{
              "childID" => " child-opencode-1 ",
              "jobID" => " job-opencode-1 ",
              "sessionID" => " session-opencode-1 ",
              "executionId" => " execution-opencode-1 ",
              "seq" => 1,
              "token" => "first"
            }
          }
        }
      })
      |> ChildSessionPanes.apply_event(%{
        event_seq: 51,
        type: :parent_call_result,
        transport: :sse,
        parent_call_id: "parent-opencode-identity-1",
        runtime_source: "opencode",
        external_ids: %{},
        occurred_at_ms: 5_100,
        raw_event: %{
          "event" => "message",
          "data" => %{
            "jsonrpc" => "2.0",
            "id" => "call-opencode-1",
            "result" => %{
              "childID" => "child-opencode-1",
              "job_id" => "job-opencode-1",
              "session_id" => "session-opencode-1",
              "execution_id" => "execution-opencode-1",
              "seq" => 2,
              "ok" => true
            }
          }
        }
      })

    pane_id = "child-session:child-opencode-1"

    assert state.child_pane_registry == %{"child-opencode-1" => pane_id}
    assert state.focused == pane_id
    assert state.open == [pane_id]
    assert [] = state.completed

    assert [
             %{
               id: ^pane_id,
               child_id: "child-opencode-1",
               parent_call_id: "parent-opencode-identity-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "childID" => "child-opencode-1",
                 childID: "child-opencode-1",
                 job_id: "job-opencode-1",
                 session_id: "session-opencode-1",
                 execution_id: "execution-opencode-1"
               },
               stream_cursor: %{
                 transport: :sse,
                 event_seq: 51,
                 child_id: "child-opencode-1"
               },
               pane_state: %{last_event_seq: 51},
               created_at_ms: 5_000,
               updated_at_ms: 5_100
             }
           ] = state.working
  end

  test "OpenCode child-session mapping preserves upstream stream cursor" do
    state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ChildSessionPanes.apply_event(%{
        event_seq: 60,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-opencode-cursor-1",
        runtime_source: "opencode",
        external_ids: %{},
        occurred_at_ms: 6_000,
        raw_event: %{
          "event" => "message",
          "id" => "sse-cursor-1",
          "data" => %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{
              "childID" => "child-opencode-cursor-1",
              "seq" => 1,
              "token" => "first",
              "stream_cursor" => %{
                "source" => "opencode",
                "event_id" => "evt-001",
                "offset" => 128
              }
            }
          }
        }
      })
      |> ChildSessionPanes.apply_event(%{
        event_seq: 61,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-opencode-cursor-1",
        runtime_source: "opencode",
        external_ids: %{},
        occurred_at_ms: 6_100,
        raw_event: %{
          "event" => "message",
          "id" => "sse-cursor-2",
          "data" => %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{
              "childID" => "child-opencode-cursor-1",
              "seq" => 2,
              "token" => "second",
              "cursor" => %{
                "source" => "opencode",
                "event_id" => "evt-002",
                "offset" => 256
              }
            }
          }
        }
      })

    assert [
             %{
               id: "child-session:child-opencode-cursor-1",
               child_id: "child-opencode-cursor-1",
               stream_cursor: %{
                 :transport => :sse,
                 :event_seq => 61,
                 :child_id => "child-opencode-cursor-1",
                 "source" => "opencode",
                 "event_id" => "evt-002",
                 "offset" => 256
               },
               pane_state: %{
                 last_event_seq: 61,
                 stream_entries: [
                   %{payload: %{"stream_cursor" => %{"event_id" => "evt-001"}}},
                   %{payload: %{"cursor" => %{"event_id" => "evt-002"}}}
                 ]
               }
             }
           ] = state.working
  end

  test "OpenCode child-session mapping preserves cursorless upstream event payloads" do
    upstream_payload = %{
      "childID" => "child-opencode-cursorless-1",
      "kind" => "agent_event",
      "message" => %{
        "role" => "assistant",
        "parts" => [
          %{"type" => "text", "text" => "first token without upstream cursor"},
          %{"type" => "tool", "name" => "read", "input" => %{"path" => "lib/app.ex"}}
        ]
      },
      "metadata" => %{
        "source" => "opencode",
        "nested" => %{"kept" => true}
      }
    }

    state =
      ChildSessionPanes.apply_event(%{working: [], completed: [], focused: nil, open: []}, %{
        event_seq: 62,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-opencode-cursorless-1",
        runtime_source: "opencode",
        external_ids: %{},
        occurred_at_ms: 6_200,
        raw_event: %{
          "event" => "message",
          "id" => "sse-cursorless-1",
          "data" => %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => upstream_payload
          }
        }
      })

    assert [
             %{
               id: "child-session:child-opencode-cursorless-1",
               child_id: "child-opencode-cursorless-1",
               stream_cursor: %{
                 transport: :sse,
                 event_seq: 62,
                 child_id: "child-opencode-cursorless-1"
               },
               pane_state: %{
                 last_event_seq: 62,
                 stream_entries: [
                   %{
                     event_seq: 62,
                     runtime_seq: nil,
                     token: nil,
                     delta: nil,
                     content: nil,
                     payload: ^upstream_payload,
                     occurred_at_ms: 6_200
                   }
                 ]
               }
             }
           ] = state.working
  end

  test "creates a new child pane when an SSE-derived pane key is first observed" do
    state =
      ChildSessionPanes.apply_event(%{working: [], completed: [], focused: nil, open: []}, %{
        event_seq: 40,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-sse-pane-key-1",
        runtime_source: "opencode",
        external_ids: %{"session_id" => "session-sse-pane-key-1"},
        occurred_at_ms: 4_000,
        raw_event: %{
          "event" => "message",
          "data" => %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{
              "pane_key" => "child-session:child-sse-pane-key-1",
              "seq" => 1,
              "token" => "first"
            }
          }
        }
      })

    pane_id = "child-session:child-sse-pane-key-1"

    assert state.child_pane_registry == %{"child-sse-pane-key-1" => pane_id}
    assert state.focused == pane_id
    assert state.open == [pane_id]
    assert [] = state.completed

    assert [
             %{
               id: ^pane_id,
               kind: :child_session,
               status: :working,
               child_id: "child-sse-pane-key-1",
               parent_call_id: "parent-sse-pane-key-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "session_id" => "session-sse-pane-key-1",
                 "pane_key" => "child-session:child-sse-pane-key-1",
                 "child_id" => "child-sse-pane-key-1"
               },
               stream_cursor: %{
                 transport: :sse,
                 event_seq: 40,
                 child_id: "child-sse-pane-key-1"
               },
               pane_state: %{last_event_seq: 40},
               created_at_ms: 4_000,
               updated_at_ms: 4_000
             }
           ] = state.working
  end

  test "repeated SSE events with the same normalized pane key reuse the existing child pane" do
    event = fn event_seq, pane_key_field, pane_key_value, token ->
      %{
        event_seq: event_seq,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-sse-pane-key-reuse-1",
        runtime_source: "opencode",
        external_ids: %{"session_id" => "session-sse-pane-key-reuse-1"},
        occurred_at_ms: event_seq * 100,
        raw_event: %{
          "event" => "message",
          "data" => %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{
              pane_key_field => pane_key_value,
              "seq" => event_seq,
              "token" => token
            }
          }
        }
      }
    end

    pane_id = "child-session:child-sse-pane-key-reuse-1"

    state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ChildSessionPanes.apply_event(event.(41, "pane_key", " #{pane_id} ", "first"))
      |> ChildSessionPanes.apply_event(event.(42, "paneKey", pane_id, "second"))

    assert state.child_pane_registry == %{"child-sse-pane-key-reuse-1" => pane_id}
    assert state.focused == pane_id
    assert state.open == [pane_id]
    assert [] = state.completed

    assert [
             %{
               id: ^pane_id,
               child_id: "child-sse-pane-key-reuse-1",
               transport: :sse,
               external_ids: %{
                 "session_id" => "session-sse-pane-key-reuse-1",
                 "pane_key" => ^pane_id,
                 "child_id" => "child-sse-pane-key-reuse-1"
               },
               stream_cursor: %{
                 transport: :sse,
                 event_seq: 42,
                 child_id: "child-sse-pane-key-reuse-1"
               },
               pane_state: %{last_event_seq: 42},
               created_at_ms: 4_100,
               updated_at_ms: 4_200
             }
           ] = state.working
  end

  test "creation events reuse a completed pane identity instead of creating a second pane" do
    pane_id = "child-session:child-creation-2"

    state = %{
      working: [],
      completed: [
        %{
          id: pane_id,
          kind: :child_session,
          status: :completed,
          child_id: "child-creation-2",
          parent_call_id: "parent-creation-2",
          runtime_source: "opencode",
          transport: :stdio,
          external_ids: %{"session_id" => "session-creation-2", "childID" => "child-creation-2"},
          stream_cursor: %{transport: :stdio, event_seq: 1, child_id: "child-creation-2"},
          pane_state: %{
            open?: true,
            focused?: false,
            renderer: :default_child_session,
            last_event_seq: 1
          },
          created_at_ms: 100,
          updated_at_ms: 100
        }
      ],
      focused: pane_id,
      open: [pane_id],
      child_pane_registry: %{"child-creation-2" => pane_id}
    }

    state =
      ChildSessionPanes.apply_event(state, %{
        event_seq: 2,
        type: :parent_call_started,
        transport: :stdio,
        parent_call_id: "parent-creation-2",
        runtime_source: "opencode",
        external_ids: %{"thread_id" => "thread-creation-2"},
        occurred_at_ms: 200,
        params: %{"childID" => "child-creation-2"}
      })

    assert [] = state.completed
    assert state.open == [pane_id]

    assert [
             %{
               id: ^pane_id,
               status: :working,
               external_ids: %{
                 "session_id" => "session-creation-2",
                 "childID" => "child-creation-2",
                 "thread_id" => "thread-creation-2"
               },
               stream_cursor: %{event_seq: 2},
               created_at_ms: 100,
               updated_at_ms: 200
             }
           ] = state.working
  end

  test "creates a stable fallback child pane when childID is absent" do
    state = %{working: [], completed: [], focused: nil, open: []}

    state =
      ChildSessionPanes.apply_event(state, %{
        event_seq: 3,
        type: :parent_call_event,
        transport: :stdio,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-1"},
        occurred_at_ms: 300,
        notification: %{"params" => %{"seq" => 1}}
      })

    fallback_id = "fallback:session_id:session-1"

    pane_id = "child-session:" <> fallback_id

    assert [
             %{
               id: ^pane_id,
               child_id: ^fallback_id,
               parent_call_id: "parent-1",
               external_ids: %{
                 "session_id" => "session-1",
                 "child_id" => ^fallback_id,
                 "fallback_child_id" => ^fallback_id,
                 "fallback_child_id_source" => "session_id"
               },
               stream_cursor: %{event_seq: 3, child_id: ^fallback_id},
               pane_state: %{last_event_seq: 3},
               created_at_ms: 300,
               updated_at_ms: 300
             }
           ] = state.working

    assert state.focused == pane_id
    assert state.open == [pane_id]

    state =
      ChildSessionPanes.apply_event(state, %{
        event_seq: 4,
        type: :parent_call_event,
        transport: :stdio,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-1", "thread_id" => "thread-1"},
        occurred_at_ms: 400,
        notification: %{"params" => %{"seq" => 2}}
      })

    assert [
             %{
               id: ^pane_id,
               stream_cursor: %{event_seq: 4, child_id: ^fallback_id},
               external_ids: %{
                 "session_id" => "session-1",
                 "thread_id" => "thread-1",
                 "fallback_child_id" => ^fallback_id
               },
               pane_state: %{last_event_seq: 4},
               created_at_ms: 300,
               updated_at_ms: 400
             }
           ] = state.working

    assert state.open == [pane_id]
  end

  test "does not create a fallback pane when no valid fallback metadata exists" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert ChildSessionPanes.apply_event(state, %{
             event_seq: 1,
             type: :parent_call_event,
             transport: :stdio,
             parent_call_id: "parent-1",
             runtime_source: "synthetic",
             external_ids: %{},
             notification: %{"params" => %{"seq" => 1}}
           }) == state
  end

  test "fallback resolver selects stdout JSONL-derived metadata when primary runtime metadata is missing" do
    state = %{working: [], completed: [], focused: nil, open: []}

    state =
      ChildSessionPanes.apply_event(state, %{
        event_seq: 5,
        type: :parent_call_event,
        transport: :stdio,
        parent_call_id: "parent-stdout-1",
        runtime_source: "codex",
        external_ids: %{},
        occurred_at_ms: 500,
        stdout_jsonl: """
        helper boot log
        {"type":"session_configured","session_id":"stdout-session-1","thread_id":"stdout-thread-1"}
        {malformed json
        """,
        notification: %{"params" => %{"seq" => 1, "token" => "hello"}}
      })

    fallback_id = "fallback:thread_id:stdout-thread-1"
    pane_id = "child-session:" <> fallback_id

    assert [
             %{
               id: ^pane_id,
               child_id: ^fallback_id,
               external_ids: %{
                 :thread_id => "stdout-thread-1",
                 :session_id => "stdout-session-1",
                 "child_id" => ^fallback_id,
                 "fallback_child_id" => ^fallback_id,
                 "fallback_child_id_source" => "thread_id"
               },
               stream_cursor: %{event_seq: 5, child_id: ^fallback_id}
             }
           ] = state.working
  end

  test "primary runtime metadata wins over stdout JSONL-derived fallback candidates" do
    state = %{working: [], completed: [], focused: nil, open: []}

    state =
      ChildSessionPanes.apply_event(state, %{
        event_seq: 6,
        type: :parent_call_event,
        transport: :stdio,
        parent_call_id: "parent-primary-1",
        runtime_source: "codex",
        external_ids: %{"session_id" => "primary-session-1"},
        stdout_jsonl: """
        {"type":"session_configured","session_id":"stdout-session-1","thread_id":"stdout-thread-1"}
        """,
        notification: %{"params" => %{"seq" => 1, "token" => "hello"}}
      })

    fallback_id = "fallback:session_id:primary-session-1"

    assert [
             %{
               child_id: ^fallback_id,
               external_ids: %{
                 "session_id" => "primary-session-1",
                 :thread_id => "stdout-thread-1",
                 "fallback_child_id_source" => "session_id"
               }
             }
           ] = state.working
  end

  test "stdout JSONL fallback metadata wins deterministically over conflicting runtime event metadata" do
    state = %{working: [], completed: [], focused: nil, open: []}

    state =
      ChildSessionPanes.apply_event(state, %{
        event_seq: 8,
        type: :parent_call_event,
        transport: :stdio,
        parent_call_id: "parent-conflict-1",
        runtime_source: "codex",
        external_ids: %{},
        stdout_jsonl: """
        {"type":"session_configured","thread_id":"stdout-thread-1","session_id":"stdout-session-1"}
        """,
        raw_event: %{
          "event" => %{
            "data" => %{
              "threadId" => "runtime-thread-1",
              "sessionId" => "runtime-session-1"
            }
          }
        },
        notification: %{"params" => %{"seq" => 1, "token" => "hello"}}
      })

    fallback_id = "fallback:thread_id:stdout-thread-1"

    assert [
             %{
               child_id: ^fallback_id,
               external_ids: %{
                 :thread_id => "stdout-thread-1",
                 :session_id => "stdout-session-1",
                 "fallback_child_id_source" => "thread_id"
               },
               stream_cursor: %{event_seq: 8, child_id: ^fallback_id}
             }
           ] = state.working
  end

  test "fallback resolver selects runtime event metadata when primary and stdout metadata are missing or invalid" do
    state = %{working: [], completed: [], focused: nil, open: []}

    state =
      ChildSessionPanes.apply_event(state, %{
        event_seq: 7,
        type: :parent_call_event,
        transport: :stdio,
        parent_call_id: "parent-runtime-event-1",
        runtime_source: "codex",
        external_ids: %{
          :thread_id => " ",
          "session_id" => 123
        },
        stdout_jsonl: """
        {"type":"session_configured","thread_id":" ","session_id":42}
        """,
        raw_event: %{
          "event" => %{
            "data" => %{
              "threadId" => "runtime-thread-1",
              "sessionId" => "runtime-session-1"
            }
          }
        },
        notification: %{"params" => %{"seq" => 1, "token" => "hello"}}
      })

    fallback_id = "fallback:thread_id:runtime-thread-1"

    assert [
             %{
               child_id: ^fallback_id,
               external_ids: %{
                 :thread_id => "runtime-thread-1",
                 :session_id => "runtime-session-1",
                 "child_id" => ^fallback_id,
                 "fallback_child_id" => ^fallback_id,
                 "fallback_child_id_source" => "thread_id"
               },
               stream_cursor: %{event_seq: 7, child_id: ^fallback_id}
             }
           ] = state.working
  end

  test "ignores non-child lifecycle events" do
    state = %{working: [], completed: [], focused: nil, open: []}

    assert ChildSessionPanes.apply_event(state, %{
             event_seq: 1,
             type: :transport_connected,
             transport: :sse,
             parent_call_id: "parent-1",
             runtime_source: "synthetic",
             external_ids: %{},
             notification: %{"params" => %{"childID" => "child-1"}}
           }) == state

    assert ChildSessionPanes.apply_event(state, %{
             event_seq: 1,
             type: :transport_started,
             transport: :stdio,
             parent_call_id: "parent-1",
             runtime_source: "synthetic",
             external_ids: %{},
             occurred_at_ms: 100
           }) == state
  end

  test "summarizes streamed image payloads as stable placeholders" do
    state =
      ChildSessionPanes.apply_event(%{working: [], completed: [], focused: nil, open: []}, %{
        event_seq: 12,
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-image-1",
        runtime_source: "opencode",
        external_ids: %{"session_id" => "session-image-1"},
        notification: %{
          "params" => %{
            "childID" => "child-image-1",
            "seq" => 1,
            "token" => "render",
            "images" => [
              %{"type" => "image/png", "url" => "file:///tmp/one.png"},
              %{"mime_type" => "image/jpeg", "data" => "base64"}
            ]
          }
        }
      })

    assert [
             %{
               pane_state: %{
                 stream_entries: [
                   %{
                     token: "render",
                     media_placeholders: ["[Image #1]", "[Image #2]"]
                   }
                 ]
               }
             }
           ] = state.working
  end
end
