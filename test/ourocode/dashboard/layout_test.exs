defmodule Ourocode.Dashboard.LayoutTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.{
    ChildSessionPanes,
    Layout,
    ParentMcpPane,
    SessionListPane,
    TaskPromptInput
  }

  alias Ourocode.Journal

  test "compact layout groups Working and Completed session lists without overlap" do
    panes =
      %{
        working: SessionListPane.render([]),
        completed: SessionListPane.render_completed([]),
        focused: nil,
        open: []
      }
      |> Layout.apply_compact_session_list_layout()

    assert panes.layout.mode == :compact
    assert panes.layout.regions.session_lists.panes == [:working_sessions, :completed_sessions]
    assert panes.working.layout.region == :session_lists
    assert panes.completed.layout.region == :session_lists
    assert panes.working.layout.order == 1
    assert panes.completed.layout.order == 2

    refute Layout.overlaps?(panes.working.layout.rect, panes.completed.layout.rect)
    assert panes.working.layout.rect.x == panes.completed.layout.rect.x
    assert panes.working.layout.rect.width == panes.completed.layout.rect.width

    assert panes.completed.layout.rect.y ==
             panes.working.layout.rect.y + panes.working.layout.rect.height + 1
  end

  test "compact layout places the natural-language task prompt below session lists" do
    panes =
      %{
        working: SessionListPane.render([]),
        completed: SessionListPane.render_completed([]),
        task_prompt: TaskPromptInput.render(),
        focused: nil,
        open: []
      }
      |> Layout.apply_compact_session_list_layout()

    assert panes.layout.regions.task_prompt.panes == [:task_prompt]
    assert panes.task_prompt.layout.region == :task_prompt
    assert panes.task_prompt.layout.rect == %{x: 0, y: 22, width: 72, height: 3}

    refute Layout.overlaps?(panes.working.layout.rect, panes.task_prompt.layout.rect)
    refute Layout.overlaps?(panes.completed.layout.rect, panes.task_prompt.layout.rect)
  end

  test "detects overlap across rectangle lists and builds bounding rectangles" do
    rects = [
      %{x: 0, y: 0, width: 10, height: 4},
      %{x: 12, y: 2, width: 6, height: 3},
      %{x: 4, y: 6, width: 8, height: 2}
    ]

    assert Layout.any_overlaps?(rects) == false
    assert Layout.bounding_rect(rects) == %{x: 0, y: 0, width: 18, height: 8}

    assert Layout.any_overlaps?([
             %{x: 0, y: 0, width: 10, height: 4},
             %{x: 9, y: 3, width: 4, height: 4}
           ])
  end

  test "validates positive rectangles and container containment" do
    container = %{x: 0, y: 0, width: 80, height: 21}

    assert Layout.positive_rect?(container)
    assert Layout.contains_rect?(container, %{x: 0, y: 9, width: 80, height: 12})

    refute Layout.positive_rect?(%{x: 0, y: 0, width: 0, height: 1})
    refute Layout.contains_rect?(container, %{x: 0, y: 10, width: 80, height: 12})
    refute Layout.contains_rect?(container, %{x: -1, y: 0, width: 10, height: 1})
  end

  test "journal recovery reconstructs compact UI layout metadata after restart" do
    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-layout-recovery-#{System.unique_integer()}.jsonl")

    try do
      :ok =
        Journal.append(journal_path, %{
          event_seq: 1,
          type: :dashboard_layout_applied,
          layout: %{
            mode: :compact,
            regions: %{
              session_lists: %{
                x: 0,
                y: 0,
                width: 36,
                height: 21,
                panes: [:working_sessions, :completed_sessions]
              },
              task_prompt: %{
                x: 0,
                y: 22,
                width: 72,
                height: 3,
                panes: [:task_prompt]
              }
            }
          },
          pane_layouts: %{
            working: %{
              mode: :compact,
              region: :session_lists,
              order: 1,
              rect: %{x: 0, y: 0, width: 36, height: 10}
            },
            completed: %{
              mode: :compact,
              region: :session_lists,
              order: 2,
              rect: %{x: 0, y: 11, width: 36, height: 10}
            },
            task_prompt: %{
              mode: :compact,
              region: :task_prompt,
              order: 1,
              rect: %{x: 0, y: 22, width: 72, height: 3}
            }
          },
          focused: :task_prompt,
          open: [:working_sessions, :completed_sessions, :task_prompt]
        })

      :ok =
        Journal.append(journal_path, %{
          event_seq: 2,
          type: "dashboard_layout_updated",
          pane_layouts: %{
            "task_prompt" => %{
              "mode" => "compact",
              "region" => "task_prompt",
              "order" => 1,
              "rect" => %{"x" => 0, "y" => 24, "width" => 80, "height" => 3}
            }
          }
        })

      {:ok, events} = Journal.read_ordered(journal_path)

      recovered =
        Layout.recover_from_journal(events, %{
          working: SessionListPane.render([]),
          completed: SessionListPane.render_completed([]),
          task_prompt: TaskPromptInput.render(),
          focused: nil,
          open: []
        })

      assert recovered.layout.mode == :compact

      assert recovered.layout.regions.session_lists.panes == [
               :working_sessions,
               :completed_sessions
             ]

      assert recovered.layout.regions.task_prompt.panes == [:task_prompt]

      assert recovered.working.layout == %{
               mode: :compact,
               region: :session_lists,
               order: 1,
               rect: %{x: 0, y: 0, width: 36, height: 10}
             }

      assert recovered.completed.layout.rect == %{x: 0, y: 11, width: 36, height: 10}

      assert recovered.task_prompt.layout == %{
               mode: :compact,
               region: :task_prompt,
               order: 1,
               rect: %{x: 0, y: 24, width: 80, height: 3}
             }

      assert recovered.focused == :task_prompt
      assert recovered.open == [:working_sessions, :completed_sessions, :task_prompt]
      refute Layout.overlaps?(recovered.working.layout.rect, recovered.completed.layout.rect)
      refute Layout.overlaps?(recovered.completed.layout.rect, recovered.task_prompt.layout.rect)
    after
      File.rm(journal_path)
    end
  end

  test "streamable HTTP parent MCP call renders as the root hierarchy node" do
    parent_state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ParentMcpPane.apply_event(%{
        event_seq: 1,
        type: :parent_call_started,
        transport: :streamable_http,
        parent_call_id: "parent-http-root-1",
        runtime_source: "synthetic",
        external_ids: %{
          "session_id" => "session-http-root-1",
          "call_id" => "call-http-root-1"
        },
        occurred_at_ms: 100,
        request_id: "call-http-root-1",
        method: "tools/call",
        params: %{"name" => "ooo.run", "arguments" => %{"task" => "inspect stream hierarchy"}}
      })

    child_state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ChildSessionPanes.apply_event(%{
        event_seq: 2,
        type: :parent_call_event,
        transport: :streamable_http,
        parent_call_id: "parent-http-root-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-http-root-1"},
        occurred_at_ms: 200,
        notification: %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{"childID" => "child-http-root-1", "seq" => 1, "token" => "first"}
        }
      })

    assert %{
             id: :mcp_runtime_hierarchy,
             roots: [
               %{
                 id: "parent-mcp:parent-http-root-1",
                 kind: :parent_mcp_call,
                 parent_call_id: "parent-http-root-1",
                 runtime_source: "synthetic",
                 transport: "streamable_http",
                 request_id: "call-http-root-1",
                 method: "tools/call",
                 stream_cursor: %{
                   transport: :streamable_http,
                   parent_call_id: "parent-http-root-1",
                   event_seq: 1
                 },
                 children: [
                   %{
                     id: "child-session:child-http-root-1",
                     kind: :child_session,
                     child_id: "child-http-root-1",
                     parent_call_id: "parent-http-root-1",
                     transport: "streamable_http",
                     stream_cursor: %{
                       transport: :streamable_http,
                       event_seq: 2,
                       child_id: "child-http-root-1"
                     }
                   }
                 ]
               }
             ],
             orphan_children: []
           } = Layout.parent_child_hierarchy(parent_state, child_state)
  end

  test "runtime frame renders multiple sibling child session panes concurrently" do
    parent_state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ParentMcpPane.apply_event(%{
        event_seq: 1,
        type: :parent_call_started,
        transport: :sse,
        parent_call_id: "parent-frame-siblings-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-frame-siblings-1"},
        occurred_at_ms: 100,
        request_id: "call-frame-siblings-1",
        method: "tools/call",
        params: %{"name" => "ooo.run", "arguments" => %{"task" => "render sibling panes"}}
      })

    child_state =
      Enum.reduce(
        ["alpha", "bravo", "charlie"],
        %{working: [], completed: [], focused: nil, open: []},
        fn suffix, state ->
          event_seq = String.length(suffix)

          assert {:ok, state} =
                   ChildSessionPanes.register_child_pane(state, %{
                     child_id: "child-frame-#{suffix}",
                     parent_call_id: "parent-frame-siblings-1",
                     runtime_source: "opencode",
                     transport: :sse,
                     external_ids: %{"thread_id" => "thread-frame-#{suffix}"},
                     stream_cursor: %{event_seq: event_seq},
                     pane_state: %{
                       title: "Frame #{suffix}",
                       last_event_seq: event_seq,
                       stream_entries: [%{event_seq: event_seq, token: suffix}]
                     },
                     created_at_ms: event_seq * 100,
                     updated_at_ms: event_seq * 100
                   })

          state
        end
      )

    frame = Layout.render_runtime_frame(parent_state, child_state)
    lines = String.split(frame, "\n")

    assert [
             "MCP Runtime",
             "[starting] parent=parent-frame-siblings-1" <> _parent_tail,
             "  [working] child=child-frame-alpha" <> _alpha_tail,
             "  [working] child=child-frame-bravo" <> _bravo_tail,
             "  [working] child=child-frame-charlie" <> _charlie_tail
           ] = lines

    assert frame =~ "parent=parent-frame-siblings-1"
    assert frame =~ "pane=child-session:child-frame-alpha"
    assert frame =~ "pane=child-session:child-frame-bravo"
    assert frame =~ "pane=child-session:child-frame-charlie"

    assert length(Enum.filter(lines, &String.starts_with?(&1, "  [working] child="))) == 3
  end

  test "runtime frame preserves sibling child pane titles and stream content boundaries" do
    parent_state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ParentMcpPane.apply_event(%{
        event_seq: 1,
        type: :parent_call_started,
        transport: :sse,
        parent_call_id: "parent-boundary-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-boundary-1"},
        occurred_at_ms: 100,
        request_id: "call-boundary-1",
        method: "tools/call",
        params: %{"name" => "ooo.run", "arguments" => %{"task" => "render isolated panes"}}
      })

    child_state =
      [
        %{
          child_id: "child-boundary-alpha",
          title: "Alpha Boundary",
          token: "alpha-only-token",
          content: "alpha-only-content",
          event_seq: 10
        },
        %{
          child_id: "child-boundary-bravo",
          title: "Bravo Boundary",
          token: "bravo-only-token",
          content: "bravo-only-content",
          event_seq: 20
        }
      ]
      |> Enum.reduce(%{working: [], completed: [], focused: nil, open: []}, fn child, state ->
        assert {:ok, state} =
                 ChildSessionPanes.register_child_pane(state, %{
                   child_id: child.child_id,
                   parent_call_id: "parent-boundary-1",
                   runtime_source: "opencode",
                   transport: :sse,
                   external_ids: %{"thread_id" => "thread-#{child.child_id}"},
                   stream_cursor: %{event_seq: child.event_seq},
                   pane_state: %{
                     title: child.title,
                     last_event_seq: child.event_seq,
                     stream_entries: [
                       %{
                         event_seq: child.event_seq,
                         token: child.token,
                         content: child.content
                       }
                     ]
                   },
                   created_at_ms: child.event_seq,
                   updated_at_ms: child.event_seq
                 })

        state
      end)

    hierarchy = Layout.parent_child_hierarchy(parent_state, child_state)
    frame = Layout.render_runtime_frame(hierarchy)

    assert [
             %{
               children: [
                 %{
                   id: "child-session:child-boundary-alpha",
                   title: "Alpha Boundary",
                   stream_entries: [
                     %{event_seq: 10, token: "alpha-only-token", content: "alpha-only-content"}
                   ]
                 },
                 %{
                   id: "child-session:child-boundary-bravo",
                   title: "Bravo Boundary",
                   stream_entries: [
                     %{event_seq: 20, token: "bravo-only-token", content: "bravo-only-content"}
                   ]
                 }
               ]
             }
           ] = hierarchy.roots

    alpha_line =
      frame
      |> String.split("\n")
      |> Enum.find(&String.contains?(&1, "child=child-boundary-alpha"))

    bravo_line =
      frame
      |> String.split("\n")
      |> Enum.find(&String.contains?(&1, "child=child-boundary-bravo"))

    assert alpha_line =~ ~s(title="Alpha Boundary")
    assert alpha_line =~ "10:token=alpha-only-token,content=alpha-only-content"
    refute alpha_line =~ "Bravo Boundary"
    refute alpha_line =~ "bravo-only-token"
    refute alpha_line =~ "bravo-only-content"

    assert bravo_line =~ ~s(title="Bravo Boundary")
    assert bravo_line =~ "20:token=bravo-only-token,content=bravo-only-content"
    refute bravo_line =~ "Alpha Boundary"
    refute bravo_line =~ "alpha-only-token"
    refute bravo_line =~ "alpha-only-content"
  end

  test "runtime frame renders image placeholders without embedding image data" do
    parent_state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ParentMcpPane.apply_event(%{
        event_seq: 1,
        type: :parent_call_started,
        transport: :sse,
        parent_call_id: "parent-image-frame-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-image-frame-1"},
        occurred_at_ms: 100,
        request_id: "call-image-frame-1",
        method: "tools/call"
      })

    {:ok, child_state} =
      ChildSessionPanes.register_child_pane(
        %{working: [], completed: [], focused: nil, open: []},
        %{
          child_id: "child-image-frame-1",
          parent_call_id: "parent-image-frame-1",
          runtime_source: "opencode",
          transport: :sse,
          external_ids: %{"thread_id" => "thread-image-frame-1"},
          stream_cursor: %{event_seq: 2},
          pane_state: %{
            last_event_seq: 2,
            stream_entries: [
              %{
                event_seq: 2,
                runtime_seq: 1,
                token: "see",
                media_placeholders: ["[Image #1]"]
              }
            ]
          },
          created_at_ms: 2,
          updated_at_ms: 2
        }
      )

    frame = Layout.render_runtime_frame(parent_state, child_state)

    assert frame =~ "1:token=see,media=[Image #1]"
  end
end
