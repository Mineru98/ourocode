defmodule Ourocode.Terminal.RuntimeEventProcessorTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.RuntimeEventProcessor

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
    assert rendered =~ "+-- Plugin Status (2) region=plugin_status"
    assert rendered =~ "[OFFICIAL] id=ouroboros-plugin"
    assert rendered =~ "[THIRD-PARTY] id=vim-mode"
    assert rendered =~ "state=newly_loaded"
  end

  defp base_state(overrides) do
    Map.merge(
      %{
        journal_path: nil,
        startup_result: %{},
        runtime_events: [],
        recoverable_errors: [],
        plugin_status_updates: [],
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
