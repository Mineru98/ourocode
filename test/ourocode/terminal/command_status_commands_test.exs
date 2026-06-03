defmodule Ourocode.Terminal.CommandStatusCommandsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry
  alias Ourocode.Terminal.CommandStatusCommands

  test "handles status actions only" do
    assert CommandStatusCommands.handles?(:show_status)
    assert CommandStatusCommands.handles?(:show_plugins)
    assert CommandStatusCommands.handles?(:show_mcp)
    assert CommandStatusCommands.handles?(:show_mcps)
    assert CommandStatusCommands.handles?(:show_sandbox)
    assert CommandStatusCommands.handles?(:show_agents)
    assert CommandStatusCommands.handles?(:show_children)
    assert CommandStatusCommands.handles?(:show_sessions)
    assert CommandStatusCommands.handles?(:show_config)
    assert CommandStatusCommands.handles?(:show_queue)
    assert CommandStatusCommands.handles?(:show_hooks)
    assert CommandStatusCommands.handles?(:show_wonder_tool)
    refute CommandStatusCommands.handles?(:show_help)
    refute CommandStatusCommands.handles?(:unknown)
  end

  test "render status includes product status and sessions" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      startup_result: %{
        status: :healthy,
        runtime: %{
          status: :ready,
          journal: %{status: :ready},
          queued_notifications: %{pending_count: 1},
          hooks: %{event_count: 0},
          plugins: []
        }
      },
      pane_model: %{
        panes: %{
          "child-session:alpha" => %{
            kind: :child_session,
            child_id: "child-alpha"
          }
        }
      }
    }

    assert {:ok, %{status: :rendered}} = CommandStatusCommands.render(:show_status, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "status"
    assert text =~ "tools 0 connected"
    refute text =~ "surface="
    refute text =~ "transports="
    assert text =~ "sessions: 1 active"
    assert text =~ "child-session:alpha"
    assert text =~ "target child-alpha"
  end

  test "render sessions groups parallel children under their MCP parent" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      parent: %{
        working: [
          %{
            parent_call_id: "parent-ralph-1",
            method: "tools/call",
            params: %{name: "ouroboros_ralph"},
            transport: :streamable_http,
            stream_cursor: %{event_seq: 5}
          }
        ],
        completed: []
      },
      child: %{
        working: [
          %{
            child_id: "child-beta",
            pane_state: %{stream_entries: [%{event_seq: 4, token: "beta-start"}]}
          },
          %{
            child_id: "child-charlie",
            pane_state: %{stream_entries: [%{event_seq: 5, token: "charlie-thinking"}]}
          }
        ],
        completed: [
          %{
            child_id: "child-alpha",
            pane_state: %{stream_entries: [%{event_seq: 3, token: "alpha-done"}]}
          }
        ]
      },
      wonder: %{
        child_id: "child-beta",
        description: "Allow child beta to inspect the journal?"
      },
      mcp_topology: %{
        nodes: %{
          "mcp-parent:parent-ralph-1" => %{
            kind: :parent_call,
            parent_call_id: "parent-ralph-1",
            latest_event_seq: 5
          }
        },
        edges: %{
          "mcp-parent:parent-ralph-1->child-session:child-alpha" => %{
            parent_call_id: "parent-ralph-1",
            child_id: "child-alpha"
          },
          "mcp-parent:parent-ralph-1->child-session:child-beta" => %{
            parent_call_id: "parent-ralph-1",
            child_id: "child-beta"
          },
          "mcp-parent:parent-ralph-1->child-session:child-charlie" => %{
            parent_call_id: "parent-ralph-1",
            child_id: "child-charlie"
          }
        },
        events: []
      }
    }

    assert {:ok, %{count: 3}} = CommandStatusCommands.render(:show_sessions, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "sessions: 3 linked, 2 active"
    assert text =~ "1 MCP parent call"
    assert text =~ "MCP toolcall ouroboros_ralph  running  3 parallel sessions · 2 streaming"
    assert text =~ "parent parent-ralph-1  event 5 via streamable_http"
    assert text =~ "child-alpha  completed  alpha-done"

    assert text =~
             "child-beta  waiting permission  permission: Allow child beta to inspect the journal?"

    assert text =~ "child-charlie  streaming  charlie-thinking"
  end

  test "render sessions falls back to parent and child pane state before topology arrives" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      parent: %{
        working: [
          %{
            parent_call_id: "parent-live-1",
            params: %{name: "ouroboros_auto"},
            transport: :stdio,
            stream_cursor: %{event_seq: 2}
          }
        ],
        completed: []
      },
      child: %{
        working: [
          %{
            child_id: "child-live-1",
            parent_call_id: "parent-live-1",
            pane_state: %{stream_entries: [%{event_seq: 2, token: "drafting seed"}]}
          }
        ],
        completed: []
      }
    }

    assert {:ok, %{count: 1}} = CommandStatusCommands.render(:show_children, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "sessions: 1 linked, 1 active"
    assert text =~ "1 MCP parent call"
    assert text =~ "MCP toolcall ouroboros_auto  running  1 parallel session · 1 streaming"
    assert text =~ "child-live-1  streaming  drafting seed"
  end

  test "render simple status commands writes product status output" do
    for {action, expected} <- [
          {:show_mcp, "Connected tools"},
          {:show_mcps, "Connected tools"},
          {:show_sandbox, "guarded; 4 choices"},
          {:show_config, "Configuration"},
          {:show_queue, "queue: queued notifications are shown near the prompt"},
          {:show_hooks, "hooks: recent automation activity appears near the prompt"},
          {:show_wonder_tool, "questions: active questions render in the interaction area"}
        ] do
      {:ok, output} = StringIO.open("")

      assert {:ok, %{status: :rendered}} =
               CommandStatusCommands.render(action, %{output: output})

      {_input, text} = StringIO.contents(output)
      assert text =~ expected
      refute text =~ "streamable_http"
      refute text =~ "plugin/runtime config"
    end
  end

  test "render mcp workspace shows discovered tool schemas from the command registry" do
    {:ok, registry} =
      Registry.load(
        skill_dirs: [],
        bundled_skill_dirs: [],
        mcp_entries: [
          %{
            transport: :streamable_http,
            server_id: "ouroboros",
            tools: [
              %{
                "name" => "ouroboros_auto",
                "description" => "Run auto",
                "inputSchema" => %{
                  "required" => ["goal"],
                  "properties" => %{
                    "goal" => %{"type" => "string", "description" => "Target outcome"}
                  }
                }
              }
            ]
          }
        ]
      )

    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      startup_result: %{
        commands: registry,
        runtime: %{plugins: []}
      }
    }

    assert {:ok, %{status: :rendered, count: 1}} =
             CommandStatusCommands.render(:show_mcp, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "Connected tools"
    assert text =~ "ouroboros_auto schema"
    assert text =~ "server ouroboros"
    assert text =~ "command /ouroboros_auto"
    assert text =~ "schema args goal; required goal"
  end

  test "render mcp workspace surfaces live parent calls and parallel child panes" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      startup_result: %{runtime: %{plugins: []}},
      parent: %{
        completed: [
          %{
            parent_call_id: "parent-ralph-1",
            params: %{name: "ouroboros_ralph"}
          }
        ],
        working: []
      },
      child: %{
        working: [%{child_id: "child-beta"}],
        completed: [%{child_id: "child-alpha"}]
      },
      mcp_topology: %{
        nodes: %{
          "mcp-parent:parent-ralph-1" => %{
            id: "mcp-parent:parent-ralph-1",
            kind: :parent_call,
            parent_call_id: "parent-ralph-1",
            runtime_source: "ouroboros",
            transport: :streamable_http,
            latest_event_seq: 5
          },
          "child-session:child-alpha" => %{
            id: "child-session:child-alpha",
            kind: :child_session,
            child_id: "child-alpha",
            parent_call_id: "parent-ralph-1"
          },
          "child-session:child-beta" => %{
            id: "child-session:child-beta",
            kind: :child_session,
            child_id: "child-beta",
            parent_call_id: "parent-ralph-1"
          }
        },
        edges: %{
          "mcp-parent:parent-ralph-1->child-session:child-alpha" => %{
            parent_call_id: "parent-ralph-1",
            child_id: "child-alpha"
          },
          "mcp-parent:parent-ralph-1->child-session:child-beta" => %{
            parent_call_id: "parent-ralph-1",
            child_id: "child-beta"
          }
        },
        events: []
      }
    }

    assert {:ok, %{status: :rendered, count: 1}} =
             CommandStatusCommands.render(:show_mcp, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ ">> MCP toolcall ouroboros_ralph - completed · 2 child panes"
    assert text =~ "parent parent-ralph-1"
    assert text =~ "server ouroboros"
    assert text =~ "transport streamable_http"
    assert text =~ "stream parent pane plus linked child panes"
    assert text =~ "children child-alpha completed, child-beta streaming"
    assert text =~ "latest event 5"
    assert text =~ "Open /sessions | /agents | /verify"
    assert text =~ "Watch live MCP calls here; /sessions shows every linked child pane."
  end

  test "render sandbox shows policy, controls, and evidence" do
    {:ok, output} = StringIO.open("")

    assert {:ok, %{status: :rendered}} =
             CommandStatusCommands.render(:show_sandbox, %{output: output})

    {_input, text} = StringIO.contents(output)
    assert text =~ "Sandbox"
    assert text =~ "guarded; 4 choices"
    assert text =~ ">> Writable Roots"
    assert text =~ "allow project directory"
    assert text =~ "deny parent-directory"
    assert text =~ "Network - review required"
    assert text =~ "Shell - review required"
    assert text =~ "Recovery - ready"
    assert text =~ "Open /preflight <command> | /verify | /cancel"
  end

  test "render agents shows delegated agent lanes" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      pane_model: %{
        panes: %{
          "child-session:alpha" => %{
            kind: :child_session,
            child_id: "child-alpha",
            status: "running",
            task: "Drafting onboarding flow"
          }
        }
      }
    }

    assert {:ok, %{count: 1}} = CommandStatusCommands.render(:show_agents, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "Guided work"
    assert text =~ "running, 1 active; 1 lane"
    assert text =~ ">> Active work - running · live"
    assert text =~ "start with Drafting onboarding flow"
    refute text =~ "target · delegated work"
    refute text =~ "row actions · Focus work | /sessions | /cancel"
  end

  test "render agents treats a live interview as an active lane" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      startup_result: %{
        interview: %{
          question: "Which user should onboarding serve?",
          waiting: false,
          complete: false,
          session_id: "interview-1"
        },
        interview_session: %{label: "ooo pm", parent_call_id: "parent-1"},
        paused: true
      },
      pane_model: %{panes: %{}}
    }

    assert {:ok, %{count: 1}} = CommandStatusCommands.render(:show_agents, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "running, 1 active; 1 lane"
    assert text =~ ">> PM interview - paused"
    assert text =~ "stage paused for discussion"
    assert text =~ "start with ooo pm"
    assert text =~ "Which user should onboarding serve?"
    assert text =~ "progress question preserved, main composer open, /answer resumes"
    refute text =~ "target: interview-1"
    refute text =~ "activity: session linked"
    refute text =~ "0 active"
  end

  test "render agents shows queued, failed, and cancelled lifecycle lanes" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      pane_model: %{
        panes: %{
          "workflow:queued" => %{
            kind: :workflow_session,
            session_id: "task-queued",
            status: "queued",
            task: "ooo pm build onboarding",
            last_line: "waiting for first prompt",
            parent_call_id: "parent-queued",
            event_count: 1
          },
          "child-session:failed" => %{
            kind: :child_session,
            child_id: "child-failed",
            status: "failed",
            task: "Run evaluator",
            last_line: "model exited",
            parent_call_id: "parent-failed",
            exit_code: 1
          },
          "child-session:cancelled" => %{
            kind: :child_session,
            child_id: "child-cancelled",
            status: "cancelled",
            task: "Old evaluator",
            last_line: "cancel acknowledged",
            parent_call_id: "parent-cancelled"
          }
        }
      }
    }

    assert {:ok, %{count: 1}} = CommandStatusCommands.render(:show_agents, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "running, 1 active; 3 lanes"
    assert text =~ ">> PM interview - queued"
    assert text =~ "Attention needed - failed · needs attention"
    assert text =~ "Stopped work - cancelled · stopped"
    assert text =~ "stage queued"
    assert text =~ "progress queued, waiting for first event"
    refute text =~ "activity: work queued"
  end

  test "render agents surfaces stream and focus evidence for running panes" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      pane_model: %{
        panes: %{
          "workflow:streaming" => %{
            kind: :workflow_session,
            session_id: "task-streaming",
            status: "running",
            task: "ooo pm verify stream focus",
            last_line: "evaluator is checking the work",
            event_count: 3,
            pane_state: %{focused?: true}
          }
        }
      }
    }

    assert {:ok, %{count: 1}} = CommandStatusCommands.render(:show_agents, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ ">> PM interview - running · live"
    assert text =~ "stage updating"
    assert text =~ "progress 3 events, updates connected"
    assert text =~ "Evaluator is checking the work"
    refute text =~ "activity: work running"
  end

  test "render agents shows an empty product state" do
    {:ok, output} = StringIO.open("")

    assert {:ok, %{count: 0}} =
             CommandStatusCommands.render(:show_agents, %{
               output: output,
               pane_model: %{panes: %{}}
             })

    {_input, text} = StringIO.contents(output)
    assert text =~ "Guided work"
    assert text =~ "ready, 0 active; 3 lanes"
    assert text =~ ">> PM interview - ready"
    assert text =~ "Interview - ready"
    assert text =~ "Auto workflow - ready"
    assert text =~ "start with ooo pm <goal>"
    assert text =~ "ooo interview <goal>"
    assert text =~ "ooo auto <goal>"
    assert text =~ "Choose ooo pm <goal>, ooo interview <goal>, or ooo auto <goal>."
  end

  test "render config summarizes plugin readiness" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      startup_result: %{
        plugin_status: %{
          status: :ready,
          configured_plugins: [
            %{
              id: "ouroboros-plugin",
              source: "official",
              version: "0.2.0",
              enabled?: true,
              state: :enabled
            }
          ]
        }
      }
    }

    assert {:ok, %{status: :rendered, plugin_count: 1}} =
             CommandStatusCommands.render(:show_config, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "Configuration"
    assert text =~ "ready; 1 choice"
    assert text =~ ">> Guided workflows - enabled · ready"
    assert text =~ "Project workflow setup"
    assert text =~ "Built in"
    assert text =~ "adds commands, skills, guided work"
    refute text =~ "row actions · /plugins | /reload | /verify"
    assert text =~ "Start with ooo pm <goal>; use /verify for a health check."
    refute text =~ "runtime"
    refute text =~ "transport"
  end

  test "render plugins shows structured records and actions" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      startup_result: %{
        plugin_status: %{
          status: :ready,
          configured_plugins: [
            %{
              id: "ouroboros-plugin",
              source: "official",
              path: "plugins/ouroboros",
              enabled?: true,
              state: :loaded
            }
          ]
        }
      }
    }

    assert {:ok, %{status: :rendered, plugin_count: 1}} =
             CommandStatusCommands.render(:show_plugins, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "Plugins"
    assert text =~ "ready; 1 installed plugin"
    assert text =~ ">> Guided workflows - loaded · ready"
    assert text =~ "Guided work"
    assert text =~ "Built in"
    assert text =~ "adds commands, skills, guided work"
    refute text =~ "row actions · /plugins | /reload | /verify"
    assert text =~ "Open /mcp | /verify"
  end

  test "render sessions lists child session panes" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      pane_model: %{
        panes: %{
          "child-session:alpha" => %{
            kind: :child_session,
            child_id: "child-alpha",
            status: "running",
            task: "Drafting onboarding flow",
            last_line: "waiting for product direction"
          },
          "status" => %{kind: :runtime_status}
        }
      }
    }

    assert {:ok, %{count: 1}} = CommandStatusCommands.render(:show_sessions, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "sessions: 1 active"
    assert text =~ "child-session:alpha  running  Drafting onboarding flow"
    assert text =~ "target child-alpha"
    assert text =~ "last waiting for product direction"
    refute text =~ "runtime_status"
  end

  test "render sessions lists queued workflow workspaces" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      pane_model: %{
        panes: %{
          "workflow:task-1" => %{
            kind: :workflow_session,
            session_id: "task-1",
            status: "queued",
            task: "ooo pm build onboarding",
            last_line: "waiting for first prompt or delegated work"
          }
        }
      }
    }

    assert {:ok, %{count: 1}} = CommandStatusCommands.render(:show_children, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "sessions: 1 active"
    assert text =~ "workflow:task-1  queued  ooo pm build onboarding"
    assert text =~ "target task-1"
    assert text =~ "last waiting for first prompt or delegated work"
  end

  test "render children shows a product empty state" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      journal_path: empty_journal_path("children-empty"),
      pane_model: %{panes: %{"status" => %{kind: :runtime_status}}}
    }

    assert {:ok, %{count: 0}} = CommandStatusCommands.render(:show_children, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "sessions: 0 active"
    assert text =~ "no delegated work yet"
    assert text =~ "start with ooo pm <goal>"
    assert text =~ "ooo interview <goal>"
    assert text =~ "ooo auto <goal>"
    refute text =~ "resumable"
    refute text =~ "runtime_status"
  end

  test "render_stub writes a small status line" do
    {:ok, output} = StringIO.open("")

    assert {:ok, %{status: :rendered}} =
             CommandStatusCommands.render_stub(output, "mcp", "ready")

    {_input, text} = StringIO.contents(output)
    assert text =~ "mcp: ready"
  end

  defp empty_journal_path(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-command-status-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Path.join(dir, "active.jsonl")
  end
end
