defmodule Ourocode.Terminal.PluginStatusTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.PluginStatus

  test "status_from_reloaded_event projects configured plugin status" do
    plugin = %{"id" => "superpowers", "enabled?" => true}

    assert {:ok, status} =
             PluginStatus.status_from_reloaded_event(%{
               type: :plugin_config_reloaded,
               status: "loaded",
               request_id: "reload-1",
               configured_plugins: [plugin],
               enabled_plugins: ["superpowers"],
               load_transitions: [%{plugin_id: "superpowers", to: :enabled}]
             })

    assert status.status == "loaded"
    assert status.config_loaded? == true
    assert status.configured_plugins == [plugin]
    assert status.enabled_plugins == ["superpowers"]
    assert status.disabled_plugins == []
    assert status.plugins_by_id == %{"superpowers" => plugin}
    assert status.plugin_transitions == [%{plugin_id: "superpowers", to: :enabled}]
    assert status.last_reload == %{status: "loaded", request_id: "reload-1"}
  end

  test "status_from_reloaded_event ignores events without configured plugins" do
    assert PluginStatus.status_from_reloaded_event(%{type: :plugin_config_reloaded}) == :error
    assert PluginStatus.status_from_reloaded_event(%{configured_plugins: []}) == :error
  end

  test "put_plugin_status updates top-level, runtime, and context runtime status" do
    status = %{configured_plugins: [%{id: "superpowers"}]}

    startup =
      PluginStatus.put_plugin_status(
        %{runtime: %{existing: true}, context: %{runtime: %{nested: true}}},
        status
      )

    assert startup.plugin_status == status
    assert startup.runtime == %{existing: true, plugin_status: status}
    assert startup.context.plugin_status == status
    assert startup.context.runtime == %{nested: true, plugin_status: status}
  end

  test "apply_reload_event records terminal status update and writes plugin status area" do
    {:ok, output} = StringIO.open("")

    state = %{
      startup_result: %{runtime: %{}, context: %{}},
      output: output,
      plugin_status_updates: []
    }

    event = %{
      type: :plugin_config_reloaded,
      status: :loaded,
      configured_plugins: [%{id: "superpowers", enabled?: true}],
      enabled_plugins: ["superpowers"],
      occurred_at_ms: 123
    }

    assert {:ok, state} = PluginStatus.apply_reload_event(event, state)

    assert state.startup_result.plugin_status.config_loaded? == true

    assert state.startup_result.runtime.plugin_status.configured_plugins == [
             %{id: "superpowers", enabled?: true}
           ]

    assert [
             %{
               type: :terminal_plugin_status_updated,
               status: :loaded,
               reload_event: ^event,
               occurred_at_ms: 123,
               ui_restart_required?: false,
               rendered_area: %{id: :plugin_status}
             }
           ] = state.plugin_status_updates

    {_input, rendered} = StringIO.contents(output)
    assert rendered =~ "plugins:"
    assert rendered =~ "superpowers"
    refute rendered =~ "region="
    refute rendered =~ "visible="
  end
end
