defmodule Ourocode.Terminal.CommandStatusCommandsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.CommandStatusCommands

  test "handles status actions only" do
    assert CommandStatusCommands.handles?(:show_status)
    assert CommandStatusCommands.handles?(:show_plugins)
    assert CommandStatusCommands.handles?(:show_mcp)
    assert CommandStatusCommands.handles?(:show_sessions)
    assert CommandStatusCommands.handles?(:show_config)
    assert CommandStatusCommands.handles?(:show_queue)
    assert CommandStatusCommands.handles?(:show_hooks)
    assert CommandStatusCommands.handles?(:show_wonder_tool)
    refute CommandStatusCommands.handles?(:show_help)
    refute CommandStatusCommands.handles?(:unknown)
  end

  test "render status includes footer, plugins, and sessions" do
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
    assert text =~ "+-- State"
    assert text =~ "+-- Plugin Status"
    assert text =~ "sessions:"
    assert text =~ "child-session:alpha session=child-alpha"
  end

  test "render simple status commands writes stub status output" do
    for {action, expected} <- [
          {:show_mcp, "mcp: stdio,SSE,streamable_http"},
          {:show_config, "config: plugin/runtime config; use /reload to reload"},
          {:show_queue, "queue: queued notifications are shown near the prompt"},
          {:show_hooks, "hooks: hook lifecycle activity is in the footer/status area"},
          {:show_wonder_tool, "wonderTool: active questions render in the interaction area"}
        ] do
      {:ok, output} = StringIO.open("")

      assert {:ok, %{status: :rendered}} =
               CommandStatusCommands.render(action, %{output: output})

      {_input, text} = StringIO.contents(output)
      assert text =~ expected
    end
  end

  test "render sessions lists child session panes" do
    {:ok, output} = StringIO.open("")

    state = %{
      output: output,
      pane_model: %{
        panes: %{
          "child-session:alpha" => %{kind: :child_session, child_id: "child-alpha"},
          "status" => %{kind: :runtime_status}
        }
      }
    }

    assert {:ok, %{count: 2}} = CommandStatusCommands.render(:show_sessions, state)

    {_input, text} = StringIO.contents(output)
    assert text =~ "sessions:"
    assert text =~ "child-session:alpha session=child-alpha"
    refute text =~ "runtime_status"
  end

  test "render_stub writes a small status line" do
    {:ok, output} = StringIO.open("")

    assert {:ok, %{status: :rendered}} =
             CommandStatusCommands.render_stub(output, "mcp", "ready")

    {_input, text} = StringIO.contents(output)
    assert text =~ "mcp: ready"
  end
end
