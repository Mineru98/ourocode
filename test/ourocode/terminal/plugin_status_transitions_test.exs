defmodule Ourocode.Terminal.PluginStatusTransitionsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.PluginStatusTransitions

  test "maps hot reload transitions onto configured plugin entries" do
    entries =
      PluginStatusTransitions.apply(
        %{
          plugin_transitions: [
            %{plugin_id: "new-tools", action: :load_requested, to: :enabled},
            %{plugin_id: "old-tools", action: :unload_requested, to: :disabled},
            %{plugin_id: "broken-tools", action: :load_failed, load_error: "boom"}
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
    assert List.last(entries).load_error == "boom"
  end

  test "uses load_transitions fallback and plugins_by_id metadata" do
    entries =
      PluginStatusTransitions.apply(
        %{
          plugins_by_id: %{
            :tools => %{id: "tools", path: "plugins/tools", enabled?: true}
          },
          load_transitions: [%{"plugin_id" => "tools", "action" => "skip_load"}]
        },
        [%{id: "tools", enabled?: true}]
      )

    assert [
             %{
               id: "tools",
               plugin_id: "tools",
               path: "plugins/tools",
               load_state: :disabled,
               status_entry: :disabled_plugin,
               enabled?: false
             }
           ] = entries
  end

  test "includes transition-only entries for unconfigured plugins" do
    assert [
             %{
               plugin_id: "removed-tools",
               load_state: :disabled,
               status_entry: :disabled_plugin
             }
           ] =
             PluginStatusTransitions.apply(
               %{plugin_transitions: [%{plugin_id: "removed-tools", action: :unload_requested}]},
               []
             )
  end

  test "returns configured plugins unchanged when no transitions exist" do
    configured = [%{id: "stable-tools", enabled?: true}]

    assert PluginStatusTransitions.apply(%{}, configured) == configured
  end
end
