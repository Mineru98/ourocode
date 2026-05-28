defmodule Ourocode.Terminal.CommandActionDispatcherTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry
  alias Ourocode.Runtime.FocusState
  alias Ourocode.Terminal.CommandActionDispatcher

  test "dispatches discovery actions" do
    {:ok, registry} = Registry.load_builtin()
    {:ok, output} = StringIO.open("")

    assert {:ok, %{count: count}} =
             CommandActionDispatcher.dispatch(
               :show_help,
               %{args: []},
               %{slash: "/help"},
               %{output: output},
               registry
             )

    assert count > 0

    {_input, text} = StringIO.contents(output)
    assert text =~ "help"
    assert text =~ "/theme"
    assert text =~ "/config"
  end

  test "dispatches command preflight action" do
    {:ok, registry} = Registry.load_builtin()
    {:ok, output} = StringIO.open("")

    assert {:ok, %{preflight: %{status: :ready}}} =
             CommandActionDispatcher.dispatch(
               :show_preflight,
               %{args: ["/help"]},
               %{slash: "/preflight"},
               %{output: output},
               registry
             )

    {_input, text} = StringIO.contents(output)
    assert text =~ "preflight: ready"
    assert text =~ "command: /help"
    assert text =~ "execution: preview only"
    refute text =~ "plugin_path"
    refute text =~ "source:"
  end

  test "dispatches product verify guidance" do
    {:ok, registry} = Registry.load_builtin()
    {:ok, output} = StringIO.open("")

    assert {:ok, %{verify: %{status: :ready}}} =
             CommandActionDispatcher.dispatch(
               :show_verify,
               %{args: []},
               %{slash: "/verify"},
               %{output: output},
               registry
             )

    {_input, text} = StringIO.contents(output)
    assert text =~ "verify: ready"
    assert text =~ "startup, plugins, preflight, guided work, real terminal replay"
    assert text =~ "ourocode --verify --format json --project-dir ."
    refute text =~ "source:"
    refute text =~ "plugin_path"
  end

  test "dispatches status actions" do
    {:ok, output} = StringIO.open("")

    assert {:ok, %{status: :rendered}} =
             CommandActionDispatcher.dispatch(
               :show_mcp,
               %{args: []},
               %{slash: "/mcp"},
               %{output: output},
               %{}
             )

    {_input, text} = StringIO.contents(output)
    assert text =~ "Connected tools"
    assert text =~ "not configured; 0 connected tools"
    assert text =~ "nothing here yet"
    assert text =~ "No connected tool configured."
    assert text =~ "Open /plugins | /verify"
    refute text =~ "streamable_http"
  end

  test "dispatches resume actions" do
    dir = tmp_dir!("command-action-dispatcher-resume")
    active_path = Path.join(dir, "active.jsonl")
    session_path = Path.join(dir, "session-alpha.jsonl")

    Ourocode.Journal.append!(session_path, %{type: :event, event_seq: 1})

    {:ok, output} = StringIO.open("")

    assert {:ok, %{sessions: [%{id: "session-alpha"}]}} =
             CommandActionDispatcher.dispatch(
               :resume_session,
               %{args: []},
               %{slash: "/resume"},
               %{output: output, journal_path: active_path},
               %{}
             )
  end

  test "dispatches focused child control actions" do
    parent = self()
    pane_model = pane_model()

    {:ok, focus_state, _event} =
      FocusState.focus_pane(FocusState.new(), "child-session:alpha", pane_model)

    state = %{
      focus_state: focus_state,
      pane_model: pane_model,
      command_dispatch_options: %{
        child_session_interrupt_dispatcher: fn pane, serialized_request, context ->
          send(parent, {:interrupt, pane, serialized_request, context})
          {:ok, :interrupted}
        end
      }
    }

    assert {:ok, %{delivery_result: :interrupted}} =
             CommandActionDispatcher.dispatch(
               :interrupt_focused_child,
               %{command: "/interrupt", args: ["stop"]},
               %{slash: "/interrupt"},
               state,
               %{}
             )

    assert_receive {:interrupt, %{id: "child-session:alpha"}, serialized_request, context}
    assert is_binary(serialized_request)
    assert context.decoded_request.action == "interrupt"
  end

  test "dispatches auto workflow approval through runtime events" do
    {:ok, output} = StringIO.open("")

    state = %{
      startup_result: %{status: :healthy},
      output: output,
      journal_path: nil,
      runtime_events: [],
      recoverable_errors: [],
      on_runtime_event: fn _event, _startup -> :ok end,
      pane_model: %{
        panes: %{
          "workflow:auto-1" => %{
            id: "workflow:auto-1",
            kind: :workflow_session,
            title: "Auto run",
            status: "preparing approval",
            task: "ooo auto improve startup",
            last_line: "interview -> plan -> approval -> verify",
            progress: "approval checkpoint before file changes"
          }
        },
        open: ["workflow:auto-1"]
      }
    }

    assert {:ok,
            %{
              state: approved,
              approval: %{status: :approved_sandbox_execution, sandbox_path: sandbox_path}
            }} =
             CommandActionDispatcher.dispatch(
               :approve_workflow,
               %{command: "/approve", args: []},
               %{slash: "/approve"},
               state,
               %{}
             )

    pane = approved.pane_model.panes["workflow:auto-1"]
    assert pane.status == "running"
    assert pane.phase == "verify sandbox"

    assert pane.current ==
             "sandbox verification passed; project mutation still requires explicit execution"

    assert pane.progress == [
             "approval journaled",
             "sandbox verified",
             sandbox_path,
             "project files unchanged"
           ]

    assert length(approved.runtime_events) == 2
    assert File.exists?(sandbox_path)

    {_input, text} = StringIO.contents(output)
    assert text =~ "approval: sandbox execution accepted"
    assert text =~ "changed and verified a temporary sandbox file"
    assert text =~ "project: unchanged"
  end

  test "returns command metadata for actions owned elsewhere" do
    entry = %{slash: "/clear", run_spec: %{action: :clear_screen}}

    assert CommandActionDispatcher.dispatch(:clear_screen, %{args: []}, entry, %{}, %{}) ==
             {:ok, %{command_entry: entry}}
  end

  defp pane_model do
    %{
      panes: %{
        :parent => %{id: :parent, kind: :parent_session, session_id: "parent"},
        "child-session:alpha" => %{
          id: "child-session:alpha",
          kind: :child_session,
          child_id: "alpha"
        }
      },
      open: [:parent, "child-session:alpha"]
    }
  end

  defp tmp_dir!(name) do
    path = Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
