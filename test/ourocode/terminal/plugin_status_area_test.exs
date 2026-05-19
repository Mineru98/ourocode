defmodule Ourocode.Terminal.PluginStatusAreaTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.Loader
  alias Ourocode.Terminal.PluginStatusArea

  test "renders one visible terminal row per normalized plugin status entry" do
    report = %{
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
          enabled?: false,
          load_state: :disabled,
          path: "plugins/vim-mode"
        }
      ]
    }

    area = PluginStatusArea.render(%{runtime: %{plugin_status: report}})

    assert area.id == :plugin_status
    assert area.kind == :terminal_plugin_status_area
    assert area.status == :ready
    assert area.plugin_count == 2
    assert area.visible_count == 2
    assert length(area.items) == 2
    assert Enum.map(area.items, & &1.source_label) == ["Official plugin", "Third-party plugin"]
    assert Enum.map(area.items, & &1.source_badge) == ["[OFFICIAL]", "[THIRD-PARTY]"]

    text = PluginStatusArea.render_text(area)

    assert text =~ "+-- Plugin Status (2) region=plugin_status"
    assert text =~ "| status=ready visible=2"

    assert text =~
             "| plugin [OFFICIAL] id=ouroboros-plugin label=Official plugin source=official version=0.1.0 enabled?=true state=load_requested path=plugins/ouroboros"

    assert text =~
             "| plugin [THIRD-PARTY] id=vim-mode label=Third-party plugin source=third_party version=1.4.2 enabled?=false state=disabled path=plugins/vim-mode"

    assert text |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "| plugin ")) == 2
  end

  test "derives the visible status rows from a parsed plugin config" do
    assert {:ok, %ConfigSchema{} = config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "ouroboros-plugin", "version": "0.2.0"},
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "source": "official",
                   "permissions": {
                     "filesystem": ["plugins/ouroboros"],
                     "network": [],
                     "process": []
                   }
                 },
                 {
                   "identity": {"id": "vim-mode", "version": "1.4.2"},
                   "path": "plugins/vim-mode",
                   "entrypoint": {"type": "executable", "command": "bin/vim-mode"},
                   "enabled": true,
                   "source": "third_party",
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": ["bin/vim-mode"]
                   }
                 }
               ]
             }
             """)

    expected_report = Loader.config_status_report(config)

    area = PluginStatusArea.render(%{context: %{plugin_config: config}})

    assert area.plugin_count == length(expected_report.plugins)
    assert Enum.map(area.items, & &1.plugin_id) == ["ouroboros-plugin", "vim-mode"]

    text = PluginStatusArea.render_text(area)

    assert text =~ "[OFFICIAL] id=ouroboros-plugin label=Official plugin"
    assert text =~ "[THIRD-PARTY] id=vim-mode label=Third-party plugin"
    assert text =~ "label=Official plugin source=official version=0.2.0"
    assert text =~ "label=Third-party plugin source=third_party version=1.4.2"
  end

  test "labels plugins from normalized source metadata projections" do
    text =
      PluginStatusArea.render_text([
        %{
          plugin_id: "official-tools",
          source_metadata: %{"source" => "official"},
          version: "1.0.0",
          enabled?: true,
          load_state: :loaded,
          path: "plugins/official-tools"
        },
        %{
          plugin_id: "vim-mode",
          source_attribution: %{plugin_source: "third_party"},
          version: "2.0.0",
          enabled?: true,
          load_state: :loaded,
          path: "plugins/vim-mode"
        }
      ])

    assert text =~ "[OFFICIAL] id=official-tools label=Official plugin source=official"
    assert text =~ "[THIRD-PARTY] id=vim-mode label=Third-party plugin source=third_party"
  end

  test "renders runtime hot reload configured plugin records directly" do
    text =
      PluginStatusArea.render_text(%{
        status: :ready,
        configured_plugins: [
          %{
            id: "ouroboros-plugin",
            source: "official",
            enabled?: true,
            state: :enabled,
            path: "plugins/ouroboros"
          }
        ]
      })

    assert text =~ "+-- Plugin Status (1)"
    assert text =~ "[OFFICIAL] id=ouroboros-plugin"
    assert text =~ "enabled?=true state=enabled"
    refute text =~ "id=nil"
  end

  test "maps hot reload plugin transitions into distinct UI status entries" do
    failure = %{
      plugin_id: "broken-tools",
      reason: :missing_capability_manifest,
      message: "plugin manifest is missing"
    }

    area =
      PluginStatusArea.render(%{
        status: :ready,
        configured_plugins: [
          %{
            id: "ouroboros-plugin",
            source: "official",
            enabled?: true,
            state: :enabled,
            path: "plugins/ouroboros"
          },
          %{
            id: "vim-mode",
            source: "third_party",
            enabled?: false,
            state: :disabled,
            path: "plugins/vim-mode"
          },
          %{
            id: "broken-tools",
            source: "third_party",
            enabled?: true,
            state: :load_failed,
            path: "plugins/broken-tools",
            load_error: failure
          }
        ],
        plugin_transitions: [
          %{
            plugin_id: "ouroboros-plugin",
            from: :unconfigured,
            to: :enabled,
            action: :load_requested,
            reason: :enabled_in_config
          },
          %{
            plugin_id: "vim-mode",
            from: :enabled,
            to: :disabled,
            action: :unload_requested,
            reason: :disabled_in_config
          },
          %{
            plugin_id: "broken-tools",
            from: :enabled,
            to: :load_failed,
            action: :load_failed,
            reason: :missing_capability_manifest,
            load_error: failure
          }
        ]
      })

    assert Enum.map(area.items, & &1.plugin_id) == [
             "ouroboros-plugin",
             "vim-mode",
             "broken-tools"
           ]

    assert Enum.map(area.items, & &1.status_entry) == [
             :newly_loaded_plugin,
             :disabled_plugin,
             :failed_plugin
           ]

    assert Enum.map(area.items, & &1.load_state) == [
             :newly_loaded,
             :disabled,
             :load_failed
           ]

    assert Enum.map(area.items, & &1.enabled?) == [true, false, true]

    text = PluginStatusArea.render_text(area)

    assert text =~ "[OFFICIAL] id=ouroboros-plugin"
    assert text =~ "state=newly_loaded"
    assert text =~ "[THIRD-PARTY] id=vim-mode"
    assert text =~ "state=disabled"
    assert text =~ "[THIRD-PARTY] id=broken-tools"
    assert text =~ "state=load_failed"
  end

  test "renders an empty plugin status surface before plugin state attaches" do
    text = PluginStatusArea.render_text(%{})

    assert text =~ "+-- Plugin Status (0)"
    assert text =~ "| status=unknown visible=0"
    assert text =~ "| empty"
  end
end
