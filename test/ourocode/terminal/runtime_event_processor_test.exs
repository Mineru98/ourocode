defmodule Ourocode.Terminal.RuntimeEventProcessorTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.FocusState
  alias Ourocode.Terminal.RuntimeEventProcessor
  alias Ourocode.Terminal.{WorkspaceModel, WorkspaceText}

  test "submit records handler failures as recoverable while keeping the runtime event" do
    state =
      base_state(%{
        on_runtime_event: fn _event, _startup_result -> {:error, :temporary_failure} end
      })

    assert {:ok, state} = RuntimeEventProcessor.submit(%{type: :child_event}, state)

    assert [%{type: :child_event}] = state.runtime_events

    assert [
             %{
               type: :terminal_recoverable_error,
               error_type: :runtime_event_handler_failed,
               reason: :temporary_failure,
               source: :child_event
             }
           ] = state.recoverable_errors
  end

  test "drain polls runtime events until the poller returns none" do
    {:ok, poller} = Agent.start_link(fn -> [%{type: :first}, %{type: :second}] end)

    state =
      base_state(%{
        poll_runtime_event: fn _state ->
          Agent.get_and_update(poller, fn
            [event | rest] -> {event, rest}
            [] -> {:none, []}
          end)
        end
      })

    assert {:ok, state} = RuntimeEventProcessor.drain(state)
    assert Enum.map(state.runtime_events, & &1.type) == [:second, :first]
  end

  test "submit applies runtime workflow lifecycle events to the pane model" do
    state =
      base_state(%{
        pane_model: %{
          panes: %{
            "workflow:task-1" => %{
              id: "workflow:task-1",
              kind: :workflow_session,
              session_id: "task-1",
              status: "queued",
              task: "ooo pm verify lifecycle",
              last_line: "waiting for first prompt"
            }
          },
          open: ["workflow:task-1"]
        }
      })

    assert {:ok, state} =
             RuntimeEventProcessor.submit(
               %{
                 type: :stream_started,
                 pane_id: "workflow:task-1",
                 line: "stream: runtime event arrived",
                 parent_call_id: "parent-runtime",
                 focused?: true
               },
               state
             )

    assert {:ok, state} =
             RuntimeEventProcessor.submit(
               %{type: :paused, pane_id: "workflow:task-1", line: "paused by user"},
               state
             )

    assert get_in(state.pane_model, [:panes, "workflow:task-1", :status]) == "paused"
    assert get_in(state.pane_model, [:panes, "workflow:task-1", :event_count]) == 2

    text =
      "/agents"
      |> WorkspaceModel.build(%{startup_result: %{}, pane_model: state.pane_model}, %{})
      |> WorkspaceText.render()

    assert text =~ "paused"
    assert text =~ "stage paused"
    assert text =~ "Paused by user"
    refute text =~ "focused in workspace"
    refute text =~ "updates received"
  end

  test "submit registers background Ouroboros jobs as concrete child panes" do
    state = base_state(%{})

    assert {:ok, state} =
             RuntimeEventProcessor.submit(
               %{
                 type: :child_session_registered,
                 pane_id: "child-session:job-auto-1",
                 child_id: "job-auto-1",
                 parent_call_id: "parent-auto-1",
                 runtime_source: "ouroboros",
                 transport: :streamable_http,
                 external_ids: %{"job_id" => "job-auto-1"},
                 title: "Ouroboros job job-auto-1",
                 line: "Auto started"
               },
               state
             )

    assert get_in(state.pane_model, [:panes, "child-session:job-auto-1", :kind]) ==
             :child_session

    assert state.pane_model.open == ["child-session:job-auto-1"]

    text =
      "/agents"
      |> WorkspaceModel.build(%{startup_result: %{}, pane_model: state.pane_model}, %{})
      |> WorkspaceText.render()

    assert text =~ "job-auto-1"
    assert text =~ "Auto started"

    assert {:ok, focus_state, _event} =
             FocusState.focus_pane(
               FocusState.new(),
               "child-session:job-auto-1",
               state.pane_model
             )

    assert {:ok,
            %{
              pane_id: "child-session:job-auto-1",
              session_id: "job-auto-1",
              child_id: "job-auto-1"
            }} = FocusState.focused_child_session(focus_state, state.pane_model)
  end

  test "submit applies plugin reload status and renders the plugin status area" do
    {:ok, output} = StringIO.open("")
    event = plugin_config_reloaded_event()
    state = base_state(%{output: output})

    assert {:ok, state} = RuntimeEventProcessor.submit(event, state)

    assert [%{type: :plugin_config_reloaded}] = state.runtime_events

    assert [
             %{
               type: :terminal_plugin_status_updated,
               status: :loaded,
               ui_restart_required?: false,
               rendered_area: %{plugin_count: 2, items: items}
             }
           ] = state.plugin_status_updates

    assert Enum.map(items, & &1.plugin_id) == ["ouroboros-plugin", "vim-mode"]
    assert Enum.map(items, & &1.load_state) == [:newly_loaded, :newly_loaded]
    assert Enum.map(items, & &1.enabled?) == [true, true]

    {_input, rendered} = StringIO.contents(output)
    assert rendered =~ "plugins: 2 available"
    assert rendered =~ "[BUILT-IN] Guided workflows"
    assert rendered =~ "[EXTENSION] vim-mode"
    assert rendered =~ "loaded"
    refute rendered =~ "ouroboros-plugin"
    refute rendered =~ "state="
    refute rendered =~ "region="
    refute rendered =~ "visible="
  end

  defp base_state(overrides) do
    Map.merge(
      %{
        journal_path: nil,
        startup_result: %{},
        runtime_events: [],
        recoverable_errors: [],
        plugin_status_updates: [],
        pane_model: %{panes: %{}, open: []},
        output: :stdio,
        on_runtime_event: fn _event, _startup_result -> :ok end,
        poll_runtime_event: fn _state -> :none end
      },
      overrides
    )
  end

  defp plugin_config_reloaded_event do
    %{
      type: :plugin_config_reloaded,
      event_type: :plugin_config_reloaded,
      source: :plugin_registry,
      status: :loaded,
      request_id: "reload-loaded",
      change: :modified,
      configured_plugins: [
        %{
          id: "ouroboros-plugin",
          source: "official",
          version: "0.1.0",
          enabled?: true,
          state: :enabled,
          path: "plugins/ouroboros"
        },
        %{
          id: "vim-mode",
          source: "third_party",
          version: "1.4.2",
          enabled?: true,
          state: :enabled,
          path: "plugins/vim-mode"
        }
      ],
      enabled_plugins: ["ouroboros-plugin", "vim-mode"],
      disabled_plugins: [],
      load_transitions: [
        %{
          plugin_id: "ouroboros-plugin",
          from: :unconfigured,
          to: :enabled,
          action: :load_requested,
          reason: :enabled_in_config
        },
        %{
          plugin_id: "vim-mode",
          from: :unconfigured,
          to: :enabled,
          action: :load_requested,
          reason: :enabled_in_config
        }
      ],
      occurred_at_ms: System.system_time(:millisecond),
      reload_boundary: :elixir_runtime,
      ui_restart_required?: false
    }
  end
end
