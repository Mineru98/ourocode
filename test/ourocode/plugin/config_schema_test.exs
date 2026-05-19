defmodule Ourocode.Plugin.ConfigSchemaTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Json

  test "parses official Ouroboros plugin configuration files into internal config model" do
    config_path =
      tmp_config_file!("official-ouroboros-plugin", """
      {
        "plugins": [
          {
            "identity": {
              "id": "ouroboros-plugin",
              "name": "Ouroboros",
              "version": "0.1.0"
            },
            "path": "plugins/ouroboros",
            "entrypoint": {
              "type": "elixir_module",
              "module": "Ourocode.Plugin.Ouroboros"
            },
            "enabled": true,
            "source": "official",
            "expected_checksum": "abc123",
            "manifest_filename": "capabilities.json",
            "permissions": {
              "filesystem": ["plugins/ouroboros"],
              "network": [],
              "process": []
            },
            "trust_policy": {
              "tier": "official",
              "signature_key_id": "official-plugin-key"
            },
            "provenance": {
              "publisher": "ouroboros",
              "distribution": "bundled"
            },
            "config": {
              "commands": true,
              "skills": true
            }
          }
        ]
      }
      """)

    assert {:ok,
            %{
              plugins: [
                %{
                  id: "ouroboros-plugin",
                  identity: %{
                    "id" => "ouroboros-plugin",
                    "name" => "Ouroboros",
                    "version" => "0.1.0"
                  },
                  path: "plugins/ouroboros",
                  entrypoint: %{
                    "type" => "elixir_module",
                    "module" => "Ourocode.Plugin.Ouroboros"
                  },
                  enabled: true,
                  source: "official",
                  expected_checksum: "abc123",
                  manifest_filename: "capabilities.json",
                  permissions: %{
                    "filesystem" => ["plugins/ouroboros"],
                    "network" => [],
                    "process" => []
                  },
                  trust_policy: %{
                    "tier" => "official",
                    "signature_key_id" => "official-plugin-key",
                    "requires_explicit_approval" => false
                  },
                  provenance: %{
                    "publisher" => "ouroboros",
                    "distribution" => "bundled"
                  },
                  config: %{
                    "commands" => true,
                    "skills" => true
                  }
                }
              ]
            }} = ConfigSchema.parse_file(config_path)
  end

  test "parses explicit enabled and disabled plugin states during config load" do
    assert {:ok,
            %ConfigSchema{
              plugins: [
                %ConfigSchema.PluginEntry{id: "enabled-plugin", enabled: true},
                %ConfigSchema.PluginEntry{id: "disabled-plugin", enabled: false},
                %ConfigSchema.PluginEntry{id: "default-enabled-plugin", enabled: true}
              ]
            } = config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "enabled-plugin", "version": "1.0.0"},
                   "path": "plugins/enabled-plugin",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "enabled": true,
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   }
                 },
                 {
                   "identity": {"id": "disabled-plugin", "version": "1.0.0"},
                   "path": "plugins/disabled-plugin",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "enabled": false,
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   }
                 },
                 {
                   "identity": {"id": "default-enabled-plugin", "version": "1.0.0"},
                   "path": "plugins/default-enabled-plugin",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert config
           |> ConfigSchema.to_map()
           |> get_in(["plugins", Access.all(), "enabled"]) == [true, false, true]
  end

  test "saves plugin enabled and disabled state transitions without losing booleans" do
    config_path =
      tmp_config_file!("enabled-state-transition", """
      {
        "plugins": [
          {
            "identity": {"id": "official-toggle", "version": "1.0.0"},
            "path": "plugins/official-toggle",
            "entrypoint": {"type": "manifest", "path": "capabilities.json"},
            "enabled": true,
            "permissions": {
              "filesystem": [],
              "network": [],
              "process": []
            }
          },
          {
            "identity": {"id": "vim-mode", "version": "1.0.0"},
            "path": "plugins/vim-mode",
            "entrypoint": {"type": "manifest", "path": "capabilities.json"},
            "enabled": false,
            "permissions": {
              "filesystem": [],
              "network": [],
              "process": []
            }
          }
        ]
      }
      """)

    assert {:ok, %ConfigSchema{} = config} = ConfigSchema.parse_file(config_path)

    transitioned =
      %ConfigSchema{
        config
        | plugins:
            Enum.map(config.plugins, fn
              %ConfigSchema.PluginEntry{id: "official-toggle"} = plugin ->
                %{plugin | enabled: false}

              %ConfigSchema.PluginEntry{id: "vim-mode"} = plugin ->
                %{plugin | enabled: true}
            end)
      }

    assert :ok = ConfigSchema.save_file(transitioned, config_path)
    assert {:ok, saved_json} = File.read(config_path)
    assert {:ok, saved_map} = Json.decode(saved_json)

    assert saved_map
           |> get_in(["plugins", Access.all(), "enabled"]) == [false, true]

    assert {:ok,
            %ConfigSchema{
              plugins: [
                %ConfigSchema.PluginEntry{id: "official-toggle", enabled: false},
                %ConfigSchema.PluginEntry{id: "vim-mode", enabled: true}
              ]
            }} = ConfigSchema.parse_file(config_path)
  end

  test "defaults official trust policy for canonical official plugin config" do
    assert {:ok,
            %{
              plugins: [
                %{
                  id: "ouroboros-plugin",
                  identity: %{"id" => "ouroboros-plugin", "version" => "0.1.0"},
                  entrypoint: %{"type" => "manifest", "path" => "capabilities.json"},
                  enabled: true,
                  source: "official",
                  permissions: %{
                    "filesystem" => ["plugins/ouroboros"],
                    "network" => [],
                    "process" => []
                  },
                  trust_policy: %{
                    "tier" => "official",
                    "requires_explicit_approval" => false
                  },
                  provenance: %{}
                }
              ]
            }} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "ouroboros-plugin", "version": "0.1.0"},
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "source": "official",
                   "permissions": {
                     "filesystem": ["plugins/ouroboros"],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)
  end

  test "rejects spoofed official plugin configuration" do
    assert {:error, {:invalid_plugin_config_schema, message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "ouroboros-plugin-dev", "version": "0.1.0"},
                   "path": "plugins/spoofed",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "source": "official",
                   "permissions": {
                     "filesystem": ["plugins/spoofed"],
                     "network": [],
                     "process": []
                   },
                   "trust_policy": {"tier": "official"}
                 }
               ]
             }
             """)

    assert message =~ "official plugin must be ouroboros-plugin"
  end

  test "rejects duplicate plugin IDs across config set" do
    assert {:error, {:invalid_plugin_config_schema, message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "vim-mode", "version": "1.0.0"},
                   "path": "plugins/vim-mode",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   }
                 },
                 {
                   "identity": {"id": "vim-mode", "version": "1.1.0"},
                   "path": "plugins/vim-mode-fork",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert message == "plugins[1].identity.id duplicates plugins[0].identity.id: vim-mode"
  end

  test "parses third-party plugin identity and executable entrypoint fields" do
    assert {:ok,
            %{
              plugins: [
                %{
                  id: "vim-mode",
                  identity: %{
                    "id" => "vim-mode",
                    "publisher" => "community",
                    "version" => "1.0.0"
                  },
                  entrypoint: %{
                    "type" => "executable",
                    "command" => "bin/vim-mode"
                  },
                  source: "third_party",
                  permissions: %{
                    "filesystem" => [],
                    "network" => [],
                    "process" => ["bin/vim-mode"]
                  },
                  trust_policy: %{
                    "tier" => "community_code",
                    "requires_explicit_approval" => true
                  },
                  trust_evaluation: %{
                    "plugin_id" => "vim-mode",
                    "trust_tier" => "community_code",
                    "trust_classification" => "community_code",
                    "requires_explicit_approval" => true
                  }
                }
              ]
            }} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {
                     "id": "vim-mode",
                     "publisher": "community",
                     "version": "1.0.0"
                   },
                   "path": "plugins/vim-mode",
                   "entrypoint": {
                     "type": "executable",
                     "command": "bin/vim-mode"
                   },
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": ["bin/vim-mode"]
                   }
                 }
               ]
             }
             """)
  end

  test "handles missing third-party trust policy and preserves absent default state" do
    assert {:ok, config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {
                     "id": "vim-mode",
                     "publisher": "community",
                     "version": "1.0.0"
                   },
                   "path": "plugins/vim-mode",
                   "entrypoint": {
                     "type": "executable",
                     "command": "bin/vim-mode"
                   },
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": ["bin/vim-mode"]
                   }
                 }
               ]
             }
             """)

    assert [
             %ConfigSchema.PluginEntry{
               id: "vim-mode",
               trust_policy: %{
                 "tier" => "community_code",
                 "requires_explicit_approval" => true
               },
               trust_policy_state: "absent_defaulted",
               trust_evaluation: %{
                 "plugin_id" => "vim-mode",
                 "trust_tier" => "community_code",
                 "trust_classification" => "community_code",
                 "requires_explicit_approval" => true
               }
             }
           ] = config.plugins

    assert %{
             "plugins" => [
               %{
                 "trust_policy" => %{
                   "tier" => "community_code",
                   "requires_explicit_approval" => true
                 },
                 "trust_policy_state" => "absent_defaulted"
               }
             ]
           } = ConfigSchema.to_map(config)
  end

  test "evaluates and preserves trusted plugin policy on the plugin entry" do
    assert {:ok, config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {
                     "id": "vim-mode",
                     "publisher": "community",
                     "version": "1.0.0"
                   },
                   "path": "plugins/vim-mode",
                   "entrypoint": {
                     "type": "executable",
                     "command": "bin/vim-mode"
                   },
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": ["bin/vim-mode"]
                   },
                   "trust_policy": {
                     "tier": "community-code",
                     "requires_explicit_approval": true,
                     "approval_id": "approval-vim-mode"
                   }
                 }
               ]
             }
             """)

    assert [
             %ConfigSchema.PluginEntry{
               trust_policy: %{
                 "tier" => "community-code",
                 "requires_explicit_approval" => true,
                 "approval_id" => "approval-vim-mode"
               },
               trust_policy_state: "configured",
               trust_evaluation: %{
                 "plugin_id" => "vim-mode",
                 "trust_tier" => "community-code",
                 "trust_classification" => "community_code",
                 "requires_explicit_approval" => true
               }
             }
           ] = config.plugins

    assert %{
             "plugins" => [
               %{
                 "trust_policy" => %{
                   "tier" => "community-code",
                   "requires_explicit_approval" => true,
                   "approval_id" => "approval-vim-mode"
                 },
                 "trust_policy_state" => "configured",
                 "trust_evaluation" => %{
                   "plugin_id" => "vim-mode",
                   "trust_tier" => "community-code",
                   "trust_classification" => "community_code",
                   "requires_explicit_approval" => true
                 },
                 "source_metadata" => %{
                   "trust_evaluation" => %{
                     "plugin_id" => "vim-mode",
                     "trust_tier" => "community-code",
                     "trust_classification" => "community_code",
                     "requires_explicit_approval" => true
                   }
                 }
               }
             ]
           } = ConfigSchema.to_map(config)
  end

  test "evaluates and preserves untrusted plugin policy on the plugin entry" do
    assert {:ok, config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {
                     "id": "vim-mode-experimental",
                     "publisher": "community",
                     "version": "0.2.0"
                   },
                   "path": "plugins/vim-mode-experimental",
                   "entrypoint": {
                     "type": "executable",
                     "command": "bin/vim-mode-experimental"
                   },
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": ["bin/vim-mode-experimental"]
                   },
                   "trust_policy": {
                     "tier": "untrusted",
                     "requires_explicit_approval": true,
                     "reason": "unsigned third-party plugin"
                   }
                 }
               ]
             }
             """)

    assert [
             %ConfigSchema.PluginEntry{
               id: "vim-mode-experimental",
               trust_policy: %{
                 "tier" => "untrusted",
                 "requires_explicit_approval" => true,
                 "reason" => "unsigned third-party plugin"
               },
               trust_evaluation: %{
                 "plugin_id" => "vim-mode-experimental",
                 "trust_tier" => "untrusted",
                 "trust_classification" => "untrusted",
                 "requires_explicit_approval" => true
               }
             }
           ] = config.plugins

    assert %{
             "plugins" => [
               %{
                 "trust_policy" => %{
                   "tier" => "untrusted",
                   "requires_explicit_approval" => true,
                   "reason" => "unsigned third-party plugin"
                 },
                 "trust_evaluation" => %{
                   "plugin_id" => "vim-mode-experimental",
                   "trust_tier" => "untrusted",
                   "trust_classification" => "untrusted",
                   "requires_explicit_approval" => true
                 },
                 "source_metadata" => %{
                   "trust_policy" => %{
                     "tier" => "untrusted",
                     "requires_explicit_approval" => true,
                     "reason" => "unsigned third-party plugin"
                   },
                   "trust_evaluation" => %{
                     "plugin_id" => "vim-mode-experimental",
                     "trust_tier" => "untrusted",
                     "trust_classification" => "untrusted",
                     "requires_explicit_approval" => true
                   }
                 }
               }
             ]
           } = ConfigSchema.to_map(config)
  end

  test "parses valid third-party plugin package identity version permissions and metadata" do
    assert {:ok,
            %ConfigSchema{
              plugins: [
                %ConfigSchema.PluginEntry{
                  id: "vim-mode",
                  package_identity: %ConfigSchema.PackageIdentity{
                    id: "vim-mode",
                    name: "@community/ourocode-vim-mode",
                    version: "1.4.2",
                    publisher: "community",
                    namespace: "editing",
                    package: %{
                      "name" => "@community/ourocode-vim-mode",
                      "version" => "1.4.2",
                      "publisher" => "community",
                      "namespace" => "editing"
                    }
                  },
                  entrypoint: %{
                    "type" => "executable",
                    "command" => "bin/vim-mode"
                  },
                  permissions: %{
                    "filesystem" => ["workspace:read"],
                    "network" => ["api.community.example"],
                    "process" => ["bin/vim-mode"]
                  },
                  metadata: %{
                    "description" => "Vim-like terminal editing controls.",
                    "homepage" => "https://plugins.example/vim-mode",
                    "license" => "MIT",
                    "tags" => ["editing", "vim"]
                  }
                }
              ]
            }} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {
                     "id": "vim-mode"
                   },
                   "package": {
                     "name": "@community/ourocode-vim-mode",
                     "version": "1.4.2",
                     "publisher": "community",
                     "namespace": "editing"
                   },
                   "path": "plugins/vim-mode",
                   "entrypoint": {
                     "type": "executable",
                     "command": "bin/vim-mode"
                   },
                   "permissions": {
                     "filesystem": ["workspace:read"],
                     "network": ["api.community.example"],
                     "process": ["bin/vim-mode"]
                   },
                   "metadata": {
                     "description": "Vim-like terminal editing controls.",
                     "homepage": "https://plugins.example/vim-mode",
                     "license": "MIT",
                     "tags": ["editing", "vim"]
                   }
                 }
               ]
             }
             """)
  end

  test "preserves optional plugin metadata when present" do
    assert {:ok,
            %ConfigSchema{
              plugins: [
                %ConfigSchema.PluginEntry{
                  id: "metadata-rich-plugin",
                  identity: %{
                    "id" => "metadata-rich-plugin",
                    "name" => "Metadata Rich Plugin",
                    "publisher" => "community",
                    "namespace" => "terminal",
                    "version" => "2.3.4"
                  },
                  package_identity: %ConfigSchema.PackageIdentity{
                    id: "metadata-rich-plugin",
                    name: "Metadata Rich Plugin",
                    version: "2.3.4",
                    publisher: "community",
                    namespace: "terminal",
                    package: nil
                  },
                  enabled: false,
                  source: "local",
                  provenance: %{
                    "distribution" => "workspace",
                    "loaded_from" => "plugins/metadata-rich-plugin"
                  },
                  trust_policy: %{
                    "tier" => "community_code",
                    "requires_explicit_approval" => false,
                    "approval_id" => "approval-123"
                  },
                  metadata: %{
                    "description" => "Terminal plugin with preserved optional metadata.",
                    "beta" => true,
                    "priority" => 3,
                    "released_at" => nil,
                    "tags" => ["terminal", "plugin"]
                  },
                  expected_checksum: "abc123",
                  manifest_filename: "plugin-capabilities.json",
                  config: %{
                    "commands" => true,
                    "skills" => false
                  }
                }
              ]
            }} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {
                     "id": "metadata-rich-plugin",
                     "name": "Metadata Rich Plugin",
                     "publisher": "community",
                     "namespace": "terminal",
                     "version": "2.3.4"
                   },
                   "path": "plugins/metadata-rich-plugin",
                   "entrypoint": {
                     "type": "manifest",
                     "path": "plugin-capabilities.json"
                   },
                   "enabled": false,
                   "source": "local",
                   "expected_checksum": "abc123",
                   "manifest_filename": "plugin-capabilities.json",
                   "permissions": {
                     "filesystem": ["workspace:read"],
                     "network": [],
                     "process": []
                   },
                   "trust_policy": {
                     "tier": "community_code",
                     "requires_explicit_approval": false,
                     "approval_id": "approval-123"
                   },
                   "provenance": {
                     "distribution": "workspace",
                     "loaded_from": "plugins/metadata-rich-plugin"
                   },
                   "metadata": {
                     "description": "Terminal plugin with preserved optional metadata.",
                     "beta": true,
                     "priority": 3,
                     "released_at": null,
                     "tags": ["terminal", "plugin"]
                   },
                   "config": {
                     "commands": true,
                     "skills": false
                   }
                 }
               ]
             }
             """)
  end

  test "serializes each plugin entry source metadata to JSON-safe config model" do
    assert {:ok, config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {
                     "id": "ouroboros-plugin",
                     "version": "0.1.0"
                   },
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "source": "official",
                   "permissions": {
                     "filesystem": ["plugins/ouroboros"],
                     "network": [],
                     "process": []
                   },
                   "provenance": {
                     "publisher": "ouroboros",
                     "distribution": "bundled"
                   }
                 },
                 {
                   "identity": {
                     "id": "vim-mode",
                     "publisher": "community",
                     "version": "1.4.2"
                   },
                   "path": "plugins/vim-mode",
                   "entrypoint": {"type": "executable", "command": "bin/vim-mode"},
                   "source": "third_party",
                   "permissions": {
                     "filesystem": ["workspace:read"],
                     "network": [],
                     "process": ["bin/vim-mode"]
                   },
                   "trust_policy": {
                     "tier": "community_code",
                     "approval_id": "approval-vim-mode"
                   },
                   "provenance": {
                     "registry": "github",
                     "repo": "community/ourocode-vim-mode",
                     "revision": "a1b2c3d4"
                   }
                 }
               ]
             }
             """)

    serialized =
      config
      |> ConfigSchema.encode!()
      |> IO.iodata_to_binary()
      |> Json.decode!()

    [official_plugin, third_party_plugin] = config.plugins

    assert ConfigSchema.to_map(third_party_plugin)["source_metadata"] == %{
             "id" => "vim-mode",
             "source" => "third_party",
             "package_identity" => %{
               "id" => "vim-mode",
               "name" => nil,
               "version" => "1.4.2",
               "publisher" => "community",
               "namespace" => nil,
               "package" => nil
             },
             "provenance" => %{
               "registry" => "github",
               "repo" => "community/ourocode-vim-mode",
               "revision" => "a1b2c3d4"
             },
             "trust_policy" => %{
               "tier" => "community_code",
               "requires_explicit_approval" => true,
               "approval_id" => "approval-vim-mode"
             },
             "trust_evaluation" => %{
               "plugin_id" => "vim-mode",
               "trust_tier" => "community_code",
               "trust_classification" => "community_code",
               "requires_explicit_approval" => true
             }
           }

    assert ConfigSchema.source_metadata(official_plugin)["source"] == "official"

    assert %{
             "plugins" => [
               %{
                 "id" => "ouroboros-plugin",
                 "source" => "official",
                 "source_metadata" => %{
                   "id" => "ouroboros-plugin",
                   "source" => "official",
                   "package_identity" => %{
                     "id" => "ouroboros-plugin",
                     "version" => "0.1.0"
                   },
                   "provenance" => %{
                     "publisher" => "ouroboros",
                     "distribution" => "bundled"
                   },
                   "trust_policy" => %{
                     "tier" => "official",
                     "requires_explicit_approval" => false
                   }
                 }
               },
               %{
                 "id" => "vim-mode",
                 "source" => "third_party",
                 "source_metadata" => %{
                   "id" => "vim-mode",
                   "source" => "third_party",
                   "package_identity" => %{
                     "id" => "vim-mode",
                     "publisher" => "community",
                     "version" => "1.4.2"
                   },
                   "provenance" => %{
                     "registry" => "github",
                     "repo" => "community/ourocode-vim-mode",
                     "revision" => "a1b2c3d4"
                   },
                   "trust_policy" => %{
                     "tier" => "community_code",
                     "requires_explicit_approval" => true,
                     "approval_id" => "approval-vim-mode"
                   }
                 }
               }
             ]
           } = serialized
  end

  test "serializes each plugin entry provenance metadata to JSON" do
    assert {:ok, config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {
                     "id": "ouroboros-plugin",
                     "version": "0.1.0"
                   },
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "source": "official",
                   "permissions": {
                     "filesystem": ["plugins/ouroboros"],
                     "network": [],
                     "process": []
                   },
                   "provenance": {
                     "publisher": "ouroboros",
                     "distribution": "bundled",
                     "revision": "baseline-36.1.3"
                   }
                 },
                 {
                   "identity": {
                     "id": "vim-mode",
                     "version": "1.4.2",
                     "publisher": "community"
                   },
                   "path": "plugins/vim-mode",
                   "entrypoint": {"type": "executable", "command": "bin/vim-mode"},
                   "permissions": {
                     "filesystem": ["workspace:read"],
                     "network": [],
                     "process": ["bin/vim-mode"]
                   },
                   "provenance": {
                     "registry": "github",
                     "repo": "community/ourocode-vim-mode",
                     "revision": "a1b2c3d4"
                   }
                 }
               ]
             }
             """)

    assert %{"plugins" => serialized_plugins} =
             config
             |> ConfigSchema.encode!()
             |> IO.iodata_to_binary()
             |> Json.decode!()

    assert Enum.map(serialized_plugins, & &1["id"]) == ["ouroboros-plugin", "vim-mode"]

    for plugin <- serialized_plugins do
      assert plugin["provenance"] == plugin["source_metadata"]["provenance"]
      assert is_map(plugin["provenance"])
      assert map_size(plugin["provenance"]) > 0
    end

    assert get_in(serialized_plugins, [Access.at(0), "provenance", "distribution"]) == "bundled"

    assert get_in(serialized_plugins, [Access.at(1), "provenance", "repo"]) ==
             "community/ourocode-vim-mode"
  end

  test "deserializes each plugin entry provenance metadata into the config model" do
    assert {:ok,
            %ConfigSchema{
              plugins: [
                %ConfigSchema.PluginEntry{
                  id: "ouroboros-plugin",
                  source: "official",
                  provenance: %{
                    "publisher" => "ouroboros",
                    "distribution" => "bundled",
                    "revision" => "baseline-36.1.4"
                  }
                },
                %ConfigSchema.PluginEntry{
                  id: "vim-mode",
                  source: "third_party",
                  provenance: %{
                    "registry" => "github",
                    "repo" => "community/ourocode-vim-mode",
                    "revision" => "a1b2c3d4"
                  }
                }
              ]
            } = config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {
                     "id": "ouroboros-plugin",
                     "version": "0.1.0"
                   },
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "source": "official",
                   "permissions": {
                     "filesystem": ["plugins/ouroboros"],
                     "network": [],
                     "process": []
                   },
                   "provenance": {
                     "publisher": "ouroboros",
                     "distribution": "bundled",
                     "revision": "baseline-36.1.4"
                   }
                 },
                 {
                   "identity": {
                     "id": "vim-mode",
                     "version": "1.4.2"
                   },
                   "path": "plugins/vim-mode",
                   "entrypoint": {"type": "executable", "command": "bin/vim-mode"},
                   "permissions": {
                     "filesystem": ["workspace:read"],
                     "network": [],
                     "process": ["bin/vim-mode"]
                   },
                   "provenance": {
                     "registry": "github",
                     "repo": "community/ourocode-vim-mode",
                     "revision": "a1b2c3d4"
                   }
                 }
               ]
             }
             """)

    assert config
           |> ConfigSchema.to_map()
           |> get_in(["plugins", Access.at(0), "source_metadata", "provenance"]) ==
             %{
               "publisher" => "ouroboros",
               "distribution" => "bundled",
               "revision" => "baseline-36.1.4"
             }

    assert config
           |> ConfigSchema.to_map()
           |> get_in(["plugins", Access.at(1), "source_metadata", "provenance"]) ==
             %{
               "registry" => "github",
               "repo" => "community/ourocode-vim-mode",
               "revision" => "a1b2c3d4"
             }
  end

  test "deserializes each plugin entry source metadata into the config model" do
    assert {:ok,
            %ConfigSchema{
              plugins: [
                %ConfigSchema.PluginEntry{
                  id: "ouroboros-plugin",
                  source: "official",
                  package_identity: %ConfigSchema.PackageIdentity{
                    id: "ouroboros-plugin",
                    version: "0.1.0",
                    publisher: "ouroboros"
                  },
                  provenance: %{
                    "publisher" => "ouroboros",
                    "distribution" => "bundled"
                  },
                  trust_policy: %{
                    "tier" => "official",
                    "requires_explicit_approval" => false
                  }
                },
                %ConfigSchema.PluginEntry{
                  id: "vim-mode",
                  source: "third_party",
                  package_identity: %ConfigSchema.PackageIdentity{
                    id: "vim-mode",
                    name: "@community/ourocode-vim-mode",
                    version: "1.4.2",
                    publisher: "community",
                    namespace: "editing"
                  },
                  provenance: %{
                    "registry" => "github",
                    "repo" => "community/ourocode-vim-mode",
                    "revision" => "a1b2c3d4"
                  },
                  trust_policy: %{
                    "tier" => "community_code",
                    "requires_explicit_approval" => true,
                    "approval_id" => "approval-vim-mode"
                  }
                }
              ]
            } = config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {
                     "id": "ouroboros-plugin"
                   },
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": ["plugins/ouroboros"],
                     "network": [],
                     "process": []
                   },
                   "source_metadata": {
                     "id": "ouroboros-plugin",
                     "source": "official",
                     "package_identity": {
                       "id": "ouroboros-plugin",
                       "version": "0.1.0",
                       "publisher": "ouroboros"
                     },
                     "provenance": {
                       "publisher": "ouroboros",
                       "distribution": "bundled"
                     },
                     "trust_policy": {
                       "tier": "official"
                     }
                   }
                 },
                 {
                   "identity": {
                     "id": "vim-mode"
                   },
                   "path": "plugins/vim-mode",
                   "entrypoint": {"type": "executable", "command": "bin/vim-mode"},
                   "permissions": {
                     "filesystem": ["workspace:read"],
                     "network": [],
                     "process": ["bin/vim-mode"]
                   },
                   "source_metadata": {
                     "id": "vim-mode",
                     "source": "third_party",
                     "package_identity": {
                       "id": "vim-mode",
                       "name": "@community/ourocode-vim-mode",
                       "version": "1.4.2",
                       "publisher": "community",
                       "namespace": "editing"
                     },
                     "provenance": {
                       "registry": "github",
                       "repo": "community/ourocode-vim-mode",
                       "revision": "a1b2c3d4"
                     },
                     "trust_policy": {
                       "tier": "community_code",
                       "approval_id": "approval-vim-mode"
                     }
                   }
                 }
               ]
             }
             """)

    assert config |> ConfigSchema.to_map() |> get_in(["plugins", Access.at(1), "source_metadata"]) ==
             %{
               "id" => "vim-mode",
               "source" => "third_party",
               "package_identity" => %{
                 "id" => "vim-mode",
                 "name" => "@community/ourocode-vim-mode",
                 "version" => "1.4.2",
                 "publisher" => "community",
                 "namespace" => "editing",
                 "package" => %{
                   "name" => "@community/ourocode-vim-mode",
                   "version" => "1.4.2",
                   "publisher" => "community",
                   "namespace" => "editing"
                 }
               },
               "provenance" => %{
                 "registry" => "github",
                 "repo" => "community/ourocode-vim-mode",
                 "revision" => "a1b2c3d4"
               },
               "trust_policy" => %{
                 "tier" => "community_code",
                 "requires_explicit_approval" => true,
                 "approval_id" => "approval-vim-mode"
               },
               "trust_evaluation" => %{
                 "plugin_id" => "vim-mode",
                 "trust_tier" => "community_code",
                 "trust_classification" => "community_code",
                 "requires_explicit_approval" => true
               }
             }
  end

  test "applies documented defaults and omissions when optional metadata is absent" do
    assert {:ok,
            %ConfigSchema{
              plugins: [
                %ConfigSchema.PluginEntry{
                  id: "minimal-third-party",
                  package_identity: %ConfigSchema.PackageIdentity{
                    id: "minimal-third-party",
                    name: nil,
                    version: "1.0.0",
                    publisher: nil,
                    namespace: nil,
                    package: nil
                  },
                  enabled: true,
                  source: "third_party",
                  provenance: %{},
                  trust_policy: %{
                    "tier" => "community_code",
                    "requires_explicit_approval" => true
                  },
                  transports: [],
                  settings: %{},
                  metadata: %{},
                  expected_checksum: nil,
                  manifest_filename: nil,
                  config: nil
                }
              ]
            }} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {
                     "id": "minimal-third-party",
                     "version": "1.0.0"
                   },
                   "path": "plugins/minimal-third-party",
                   "entrypoint": {
                     "type": "manifest",
                     "path": "capabilities.json"
                   },
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)
  end

  test "normalizes valid plugin settings into the plugin config model" do
    assert {:ok,
            %ConfigSchema{
              plugins: [
                %ConfigSchema.PluginEntry{
                  id: "settings-plugin",
                  settings: %{
                    "mode" => "vim",
                    "enabled_bindings" => ["normal", "insert"],
                    "repeat_count" => 3,
                    "strict" => true,
                    "fallback" => nil,
                    "palette" => %{
                      "theme" => "terminal",
                      "keys" => %{"leader" => "space"}
                    }
                  }
                }
              ]
            } = config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "settings-plugin", "version": "1.0.0"},
                   "path": "plugins/settings-plugin",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   },
                   "settings": {
                     "mode": "vim",
                     "enabled_bindings": ["normal", "insert"],
                     "repeat_count": 3,
                     "strict": true,
                     "fallback": null,
                     "palette": {
                       "theme": "terminal",
                       "keys": {"leader": "space"}
                     }
                   }
                 }
               ]
             }
             """)

    assert config
           |> ConfigSchema.to_map()
           |> get_in(["plugins", Access.at(0), "settings"]) == %{
             "mode" => "vim",
             "enabled_bindings" => ["normal", "insert"],
             "repeat_count" => 3,
             "strict" => true,
             "fallback" => nil,
             "palette" => %{
               "theme" => "terminal",
               "keys" => %{"leader" => "space"}
             }
           }
  end

  test "rejects invalid plugin settings with actionable errors" do
    assert {:error, {:invalid_plugin_config_schema, settings_type_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "bad-settings-type", "version": "1.0.0"},
                   "path": "plugins/bad-settings-type",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   },
                   "settings": []
                 }
               ]
             }
             """)

    assert settings_type_message == "plugins[0].settings must be an object"

    assert {:error, {:invalid_plugin_config_schema, key_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "bad-settings-key", "version": "1.0.0"},
                   "path": "plugins/bad-settings-key",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   },
                   "settings": {
                     " bad": true
                   }
                 }
               ]
             }
             """)

    assert key_message == "plugins[0].settings keys must be non-empty strings"

    assert {:error, {:invalid_plugin_config_schema, nested_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "bad-settings-nested", "version": "1.0.0"},
                   "path": "plugins/bad-settings-nested",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   },
                   "settings": {
                     "palette": {
                       "labels": [
                         {"ok": true},
                         "valid",
                         ["nested", {"fine": false}]
                       ],
                       "invalid": {"": "blank nested key"}
                     }
                   }
                 }
               ]
             }
             """)

    assert nested_message == "plugins[0].settings.palette.invalid keys must be non-empty strings"
  end

  test "validates runnable plugin MCP transport fields" do
    assert {:ok,
            %{
              plugins: [
                %{
                  id: "transport-plugin",
                  transports: [
                    %{
                      "type" => "stdio",
                      "command" => "bin/transport-plugin-mcp",
                      "args" => ["--stdio"]
                    },
                    %{
                      "type" => "sse",
                      "url" => "http://localhost:4000/mcp/sse"
                    },
                    %{
                      "type" => "streamable_http",
                      "url" => "http://localhost:4000/mcp"
                    }
                  ]
                }
              ]
            }} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "transport-plugin", "version": "1.0.0"},
                   "path": "plugins/transport-plugin",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": ["localhost:4000"],
                     "process": ["bin/transport-plugin-mcp"]
                   },
                   "transports": [
                     {
                       "type": "stdio",
                       "command": "bin/transport-plugin-mcp",
                       "args": ["--stdio"]
                     },
                     {
                       "type": "sse",
                       "url": "http://localhost:4000/mcp/sse"
                     },
                     {
                       "type": "streamable_http",
                       "url": "http://localhost:4000/mcp"
                     }
                   ]
                 }
               ]
             }
             """)
  end

  test "rejects plugin MCP transport entries missing required runnable fields" do
    assert {:error, {:invalid_plugin_config_schema, stdio_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "stdio-plugin", "version": "1.0.0"},
                   "path": "plugins/stdio-plugin",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   },
                   "transports": [
                     {"type": "stdio"}
                   ]
                 }
               ]
             }
             """)

    assert stdio_message ==
             "plugins[0].transports[0].command must be a non-empty string"

    assert {:error, {:invalid_plugin_config_schema, sse_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "sse-plugin", "version": "1.0.0"},
                   "path": "plugins/sse-plugin",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   },
                   "transports": [
                     {"type": "sse", "url": ""}
                   ]
                 }
               ]
             }
             """)

    assert sse_message ==
             "plugins[0].transports[0].url must be a non-empty string"

    assert {:error, {:invalid_plugin_config_schema, streamable_http_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "streamable-http-plugin", "version": "1.0.0"},
                   "path": "plugins/streamable-http-plugin",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   },
                   "transports": [
                     {"type": "streamable_http"}
                   ]
                 }
               ]
             }
             """)

    assert streamable_http_message ==
             "plugins[0].transports[0].url must be a non-empty string"
  end

  test "rejects malformed plugin MCP transport schema" do
    assert {:error, {:invalid_plugin_config_schema, list_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "bad-transport-list", "version": "1.0.0"},
                   "path": "plugins/bad-transport-list",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   },
                   "transports": "stdio"
                 }
               ]
             }
             """)

    assert list_message == "plugins[0].transports must be a list"

    assert {:error, {:invalid_plugin_config_schema, type_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "unsupported-transport", "version": "1.0.0"},
                   "path": "plugins/unsupported-transport",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   },
                   "transports": [
                     {"type": "websocket", "url": "ws://localhost:4000/mcp"}
                   ]
                 }
               ]
             }
             """)

    assert type_message ==
             "plugins[0].transports[0].type is unsupported: websocket; supported MCP transports are sse, stdio, streamable_http"
  end

  test "rejects unsupported runnable plugin MCP transport values" do
    unsupported_transports = ["websocket", "http", "streamable-http", "tcp"]

    for unsupported_transport <- unsupported_transports do
      assert {:error, {:invalid_plugin_config_schema, message}} =
               ConfigSchema.parse("""
               {
                 "plugins": [
                   {
                     "identity": {"id": "unsupported-#{unsupported_transport}", "version": "1.0.0"},
                     "path": "plugins/unsupported-#{unsupported_transport}",
                     "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                     "permissions": {
                       "filesystem": [],
                       "network": ["localhost:4000"],
                       "process": ["bin/unsupported-#{unsupported_transport}"]
                     },
                     "transports": [
                       {
                         "type": "#{unsupported_transport}",
                         "command": "bin/unsupported-#{unsupported_transport}",
                         "url": "http://localhost:4000/mcp"
                       }
                     ]
                   }
                 ]
               }
               """)

      assert message ==
               "plugins[0].transports[0].type is unsupported: #{unsupported_transport}; supported MCP transports are sse, stdio, streamable_http"
    end
  end

  test "rejects plugin entries missing required identity and entrypoint fields" do
    assert {:error, {:invalid_plugin_config_schema, identity_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "path": "plugins/missing-identity",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"}
                 }
               ]
             }
             """)

    assert identity_message == "plugins[0].identity must be an object with non-empty id"

    assert {:error, {:invalid_plugin_config_schema, version_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "missing-version"},
                   "path": "plugins/missing-version",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert version_message ==
             "plugins[0].version is required; set version, identity.version, or package.version to a non-empty string"

    assert {:error, {:invalid_plugin_config_schema, entrypoint_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "missing-entrypoint", "version": "1.0.0"},
                   "path": "plugins/missing-entrypoint"
                 }
               ]
             }
             """)

    assert entrypoint_message == "plugins[0].entrypoint must be an object"
  end

  test "validator rejects plugin definitions missing required fields" do
    valid_plugin = %{
      "identity" => %{"id" => "required-fields-plugin", "version" => "1.0.0"},
      "path" => "plugins/required-fields-plugin",
      "entrypoint" => %{"type" => "manifest", "path" => "capabilities.json"},
      "permissions" => %{
        "filesystem" => [],
        "network" => [],
        "process" => []
      }
    }

    required_field_cases = [
      {"identity", ["identity"], "plugins[0].identity must be an object with non-empty id"},
      {"version", ["identity", "version"],
       "plugins[0].version is required; set version, identity.version, or package.version to a non-empty string"},
      {"path", ["path"], "plugins[0].path must be a non-empty string"},
      {"entrypoint", ["entrypoint"], "plugins[0].entrypoint must be an object"},
      {"permissions", ["permissions"], "plugins[0].permissions must be an object"}
    ]

    for {_field, delete_path, expected_message} <- required_field_cases do
      plugin = pop_in(valid_plugin, delete_path) |> elem(1)
      config = %{"plugins" => [plugin]} |> Json.encode!() |> IO.iodata_to_binary()

      assert {:error, {:invalid_plugin_config_schema, ^expected_message}} =
               ConfigSchema.parse(config)
    end
  end

  test "rejects malformed identity and entrypoint target fields" do
    assert {:error, {:invalid_plugin_config_schema, identity_id_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "", "version": "1.0.0"},
                   "path": "plugins/bad-identity",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"}
                 }
               ]
             }
             """)

    assert identity_id_message == "plugins[0].identity.id must be a non-empty string"

    assert {:error, {:invalid_plugin_config_schema, entrypoint_module_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "bad-entrypoint", "version": "1.0.0"},
                   "path": "plugins/bad-entrypoint",
                   "entrypoint": {"type": "elixir_module"}
                 }
               ]
             }
             """)

    assert entrypoint_module_message ==
             "plugins[0].entrypoint.module must be a non-empty string"
  end

  test "rejects invalid package identity and semantic version formats" do
    assert {:error, {:invalid_plugin_config_schema, package_id_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "Bad Plugin", "version": "1.0.0"},
                   "path": "plugins/bad-plugin",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert package_id_message == "plugins[0].identity.id must use package identity format"

    assert {:error, {:invalid_plugin_config_schema, package_name_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "bad-package-name"},
                   "package": {
                     "name": "@Community/Bad Plugin",
                     "version": "1.0.0"
                   },
                   "path": "plugins/bad-package-name",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert package_name_message == "plugins[0].package.name must use package identity format"

    assert {:error, {:invalid_plugin_config_schema, version_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "bad-version", "version": "1.0"},
                   "path": "plugins/bad-version",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert version_message == "plugins[0].version must be a semantic version"
  end

  test "rejects invalid entrypoint path command permissions and metadata values" do
    assert {:error, {:invalid_plugin_config_schema, command_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "bad-command", "version": "1.0.0"},
                   "path": "plugins/bad-command",
                   "entrypoint": {"type": "executable", "command": "/usr/bin/bad-command"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": ["/usr/bin/bad-command"]
                   }
                 }
               ]
             }
             """)

    assert command_message == "plugins[0].entrypoint.command must be a relative command"

    assert {:error, {:invalid_plugin_config_schema, command_args_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "command-with-args", "version": "1.0.0"},
                   "path": "plugins/command-with-args",
                   "entrypoint": {"type": "executable", "command": "bin/plugin --stdio"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": ["bin/plugin"]
                   }
                 }
               ]
             }
             """)

    assert command_args_message == "plugins[0].entrypoint.command must not include arguments"

    assert {:error, {:invalid_plugin_config_schema, command_traversal_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "command-traversal", "version": "1.0.0"},
                   "path": "plugins/command-traversal",
                   "entrypoint": {"type": "executable", "command": "../bin/plugin"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": ["../bin/plugin"]
                   }
                 }
               ]
             }
             """)

    assert command_traversal_message ==
             "plugins[0].entrypoint.command must be a relative command inside the plugin"

    assert {:error, {:invalid_plugin_config_schema, module_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "bad-module", "version": "1.0.0"},
                   "path": "plugins/bad-module",
                   "entrypoint": {"type": "elixir_module", "module": "not a module"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert module_message == "plugins[0].entrypoint.module must be an Elixir module name"

    assert {:error, {:invalid_plugin_config_schema, path_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "bad-path", "version": "1.0.0"},
                   "path": "plugins/bad-path",
                   "entrypoint": {"type": "manifest", "path": "../capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert path_message == "plugins[0].entrypoint.path must be a relative path inside the plugin"

    assert {:error, {:invalid_plugin_config_schema, permission_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "bad-permission", "version": "1.0.0"},
                   "path": "plugins/bad-permission",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [" workspace:read "],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert permission_message ==
             "plugins[0].permissions.filesystem must be a list of non-empty strings"

    assert {:error, {:invalid_plugin_config_schema, metadata_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "bad-metadata", "version": "1.0.0"},
                   "path": "plugins/bad-metadata",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": []
                   },
                   "metadata": {
                     "author": {"name": "community"}
                   }
                 }
               ]
             }
             """)

    assert metadata_message ==
             "plugins[0].metadata.author must be a string, number, boolean, null, or list of strings"
  end

  test "rejects malformed plugin configuration schema" do
    assert ConfigSchema.parse(~s({"plugins":"bad"})) ==
             {:error, {:invalid_plugin_config_schema, "plugins must be a list"}}

    assert ConfigSchema.parse("not json") == {:error, :invalid_plugin_config_json}

    assert {:error, {:invalid_plugin_config_schema, message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "ouroboros-plugin", "version": "0.1.0"},
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "source": "official",
                   "permissions": {
                     "filesystem": ["plugins/ouroboros"],
                     "network": [],
                     "process": []
                   },
                   "expected_checksum": 123
                 }
               ]
             }
             """)

    assert message =~ "expected_checksum must be a non-empty string"
  end

  test "validates required plugin permission fields" do
    assert {:ok,
            %{
              plugins: [
                %{
                  id: "filesystem-plugin",
                  permissions: %{
                    "filesystem" => ["plugins/filesystem"],
                    "network" => ["api.example.com"],
                    "process" => []
                  }
                }
              ]
            }} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "filesystem-plugin", "version": "1.0.0"},
                   "path": "plugins/filesystem",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": ["plugins/filesystem"],
                     "network": ["api.example.com"],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert {:error, {:invalid_plugin_config_schema, missing_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "missing-permissions", "version": "1.0.0"},
                   "path": "plugins/missing-permissions",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"}
                 }
               ]
             }
             """)

    assert missing_message == "plugins[0].permissions must be an object"

    assert {:error, {:invalid_plugin_config_schema, missing_field_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "incomplete-permissions", "version": "1.0.0"},
                   "path": "plugins/incomplete-permissions",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert missing_field_message == "plugins[0].permissions.network is required"

    assert {:error, {:invalid_plugin_config_schema, invalid_field_message}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "invalid-permissions", "version": "1.0.0"},
                   "path": "plugins/invalid-permissions",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "permissions": {
                     "filesystem": [""],
                     "network": [],
                     "process": []
                   }
                 }
               ]
             }
             """)

    assert invalid_field_message ==
             "plugins[0].permissions.filesystem must be a list of non-empty strings"
  end

  defp tmp_config_file!(name, contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-plugin-config-schema-test-#{name}-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, contents)

    on_exit(fn ->
      File.rm(path)
    end)

    path
  end
end
