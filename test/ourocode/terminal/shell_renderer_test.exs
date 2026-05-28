defmodule Ourocode.Terminal.ShellRendererTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.{
    ChildSessionPanes,
    Layout,
    ParentMcpPane,
    SessionListPane,
    TaskPromptInput
  }

  alias Ourocode.Terminal.ShellRenderer

  import ExUnit.CaptureIO

  test "renders the first interactive prompt and baseline layout from terminal regions" do
    project_dir = File.cwd!()
    {parent_state, child_state} = runtime_pane_states()

    panes =
      %{
        working: SessionListPane.render([]),
        completed: SessionListPane.render_completed([]),
        task_prompt: TaskPromptInput.render(),
        focused: nil,
        open: []
      }
      |> Layout.apply_compact_session_list_layout()

    frame =
      ShellRenderer.render_initial_frame(%{
        status: :healthy,
        context: %{project_dir: project_dir, cwd: project_dir, ui_surface: :terminal},
        runtime: %{
          status: :running,
          stream: %{status: :streaming},
          journal: %{status: :ready},
          plugin_status: %{
            status: :ready,
            plugins: [
              %{
                plugin_id: "ouroboros-plugin",
                source_type: "official",
                version: "0.1.0",
                enabled?: true,
                load_state: :load_requested,
                path: "plugins/ouroboros"
              },
              %{
                plugin_id: "vim-mode",
                source_type: "third_party",
                version: "1.4.2",
                enabled?: true,
                load_state: :load_requested,
                path: "plugins/vim-mode"
              }
            ]
          },
          parent_panes: parent_state,
          child_panes: child_state,
          queued_notifications: %{
            overflow_policy: :bounded,
            replayable?: true,
            items: [
              %{
                id: "queue-1",
                source: "hook",
                target: "child-shell-renderer-1",
                priority: :high,
                event_seq: 3,
                queued_at_ms: 300,
                summary: "Review child result"
              }
            ]
          }
        },
        replayable?: true,
        transports: [
          %{type: :stdio, status: :connected},
          %{type: :sse, status: :connected},
          %{type: :streamable_http, status: :connected}
        ],
        panes: panes
      })

    assert frame =~ "ourocode agent"
    assert frame =~ "status: healthy / running"
    assert frame =~ "Start here:"
    assert frame =~ "ooo pm <goal>"
    assert frame =~ "ooo interview <goal>"
    assert frame =~ "ooo auto <goal>"
    assert frame =~ "Ready:"
    assert frame =~ "model: codex cli"
    assert frame =~ "safety preview: /preflight <command>"
    assert frame =~ "active work: /sessions"
    assert frame =~ "Automation:"
    assert frame =~ "ourocode --verify --format json --project-dir ."
    assert frame =~ "ouroboros-plugin ready to load, vim-mode ready to load"
    assert frame =~ "Prompt: Describe a task for a new session"
    assert frame =~ "Mode: compact   Focus: task_prompt"
    refute frame =~ "region="
    refute frame =~ "x=0"
    refute frame =~ "source="
    refute frame =~ "enabled?="
    refute frame =~ "event_seq"

    header_lines =
      frame
      |> String.split("\n")
      |> Enum.take(5)

    assert length(header_lines) == 5
    assert Enum.all?(header_lines, &(String.length(&1) <= 88))
  end

  test "draws the initial frame to terminal output" do
    panes =
      %{
        working: SessionListPane.render([]),
        completed: SessionListPane.render_completed([]),
        task_prompt: TaskPromptInput.render(value: "Inspect stream panes"),
        focused: nil,
        open: []
      }
      |> Layout.apply_compact_session_list_layout()

    output =
      capture_io(fn ->
        ShellRenderer.draw_initial_frame(%{
          status: :healthy,
          context: %{project_dir: "/project", cwd: "/project"},
          panes: panes
        })
      end)

    assert output =~ "ourocode agent"
    assert output =~ "Prompt: Inspect stream panes"
    assert output =~ "Start here:"
    assert output =~ "Automation:"
    refute output =~ "region="
    refute output =~ "+-- State"
    assert String.ends_with?(output, "\n")
  end

  defp runtime_pane_states do
    parent_state =
      ParentMcpPane.new()
      |> ParentMcpPane.apply_event(%{
        event_seq: 1,
        type: :parent_call_started,
        transport: :stdio,
        parent_call_id: "parent-shell-renderer-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-shell-renderer-1"},
        occurred_at_ms: 100,
        request_id: "call-shell-renderer-1",
        method: "tools/call",
        params: %{"name" => "ooo.run", "arguments" => %{"task" => "render baseline"}}
      })

    {:ok, child_state} =
      ChildSessionPanes.register_child_pane(
        ChildSessionPanes.new(),
        %{
          child_id: "child-shell-renderer-1",
          parent_call_id: "parent-shell-renderer-1",
          runtime_source: "opencode",
          transport: :stdio,
          external_ids: %{"thread_id" => "thread-shell-renderer-1"},
          stream_cursor: %{event_seq: 2},
          pane_state: %{
            title: "Shell Renderer Child",
            last_event_seq: 2,
            stream_entries: [%{event_seq: 2, token: "visible in baseline"}]
          },
          created_at_ms: 200,
          updated_at_ms: 200
        }
      )

    {parent_state, child_state}
  end
end
