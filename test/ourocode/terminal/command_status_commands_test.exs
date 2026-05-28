defmodule Ourocode.Terminal.CommandStatusCommandsTest do
  use ExUnit.Case, async: true

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
