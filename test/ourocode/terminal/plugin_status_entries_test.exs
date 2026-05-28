defmodule Ourocode.Terminal.PluginStatusEntriesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.PluginStatusEntries

  test "renders source labels and badges from normalized source metadata" do
    assert PluginStatusEntries.render_item(%{
             plugin_id: "official-tools",
             source_metadata: %{"source" => "official"},
             version: "1.0.0",
             enabled?: true,
             load_state: :loaded,
             path: "plugins/official-tools"
           }) == %{
             plugin_id: "official-tools",
             display_name: "Official tools",
             source_type: "official",
             source_label: "Official plugin",
             source_badge: "[BUILT-IN]",
             version: "1.0.0",
             version_label: "v1.0.0",
             enabled?: true,
             load_state: :loaded,
             state_label: "loaded",
             status_entry: :current,
             transition_action: nil,
             transition_reason: nil,
             path: "plugins/official-tools"
           }
  end

  test "maps hot reload transitions onto configured plugin entries" do
    entries =
      PluginStatusEntries.from_configured_plugins(
        %{
          plugin_transitions: [
            %{plugin_id: "new-tools", action: :load_requested, to: :enabled},
            %{plugin_id: "old-tools", action: :unload_requested, to: :disabled},
            %{plugin_id: "broken-tools", action: :load_failed, to: :load_failed}
          ]
        },
        [
          %{id: "new-tools", enabled?: false, state: :disabled},
          %{id: "old-tools", enabled?: true, state: :enabled},
          %{id: "broken-tools", enabled?: true, state: :enabled}
        ]
      )

    assert Enum.map(entries, & &1.load_state) == [:newly_loaded, :disabled, :load_failed]

    assert Enum.map(entries, & &1.status_entry) == [
             :newly_loaded_plugin,
             :disabled_plugin,
             :failed_plugin
           ]

    assert Enum.map(entries, & &1.enabled?) == [true, false, true]
  end

  test "includes transition-only entries when a plugin is no longer configured" do
    entries =
      PluginStatusEntries.from_configured_plugins(
        %{plugin_transitions: [%{plugin_id: "removed-tools", action: :unload_requested}]},
        []
      )

    assert [%{plugin_id: "removed-tools", load_state: :disabled, status_entry: :disabled_plugin}] =
             entries
  end
end
