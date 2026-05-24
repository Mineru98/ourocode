defmodule Ourocode.Dashboard.ChildSessionPanesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPanes
  alias Ourocode.Journal
  alias Ourocode.Journal.RelationshipRecoveryIndex
  alias Ourocode.Journal.RelationshipRecoveryRecord

  test "child pane model creation stores first-class pane linked to parent with stable id" do
    state =
      register_child!(%{
        child_id: "child-create-1",
        parent_call_id: "parent-create-1",
        external_ids: %{session_id: "session-create-1"},
        stream_cursor: %{event_seq: 7},
        pane_state: %{title: "Created child pane"},
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
    state =
      register_child!(%{
        child_id: "child-update-1",
        parent_call_id: "parent-update-1",
        transport: :sse,
        external_ids: %{session_id: "session-update-1"},
        stream_cursor: %{event_seq: 1},
        pane_state: %{title: "Original child pane"},
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
    state =
      register_child!(%{
        child_id: "child-rendered-seq-1",
        parent_call_id: "parent-rendered-seq-1",
        pane_state: %{
          stream_entries: [
            %{event_seq: 10, runtime_seq: 1, token: "alpha"},
            %{event_seq: 11, runtime_seq: 2, token: "beta"},
            %{event_seq: 12, runtime_seq: 3, token: "done"}
          ],
          last_event_seq: 12
        },
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

  defp register_child!(overrides, state \\ ChildSessionPanes.new()) do
    {:ok, state} = ChildSessionPanes.register_child_pane(state, child_metadata(overrides))
    state
  end

  defp child_metadata(overrides) do
    Map.merge(
      %{
        child_id: "child-1",
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        transport: :stdio,
        external_ids: %{},
        stream_cursor: %{},
        pane_state: %{},
        created_at_ms: 100,
        updated_at_ms: 100
      },
      overrides
    )
  end
end
