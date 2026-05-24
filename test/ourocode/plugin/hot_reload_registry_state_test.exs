defmodule Ourocode.Plugin.HotReloadRegistryStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.HotReloadRegistryState

  test "normalize_registry fills missing registry buckets" do
    assert HotReloadRegistryState.normalize_registry(%{actions: %{run: :action}}) == %{
             adapters: %{},
             renderers: %{},
             actions: %{run: :action}
           }
  end

  test "registry_sources marks every registry key with the source atom" do
    registry = %{
      adapters: %{stdio: :adapter},
      renderers: %{compact: :renderer},
      actions: %{{:session, :open} => :action}
    }

    assert HotReloadRegistryState.registry_sources(registry, :local) == %{
             adapters: %{stdio: :local},
             renderers: %{compact: :local},
             actions: %{{:session, :open} => :local}
           }
  end

  test "restores base registry and records hot reload metadata" do
    current_registry = %{
      adapters: %{},
      renderers: %{},
      actions: %{{:session, :focus} => :plugin_action}
    }

    base_registry = %{
      adapters: %{},
      renderers: %{},
      actions: %{{:session, :open} => :runtime_action}
    }

    state = %{
      generation: 4,
      registry: current_registry,
      base_registry: base_registry,
      base_sources: %{
        adapters: %{},
        renderers: %{},
        actions: %{{:session, :open} => :local}
      }
    }

    plugin_status = %{id: "plugin-a", state: :disabled}

    restored =
      HotReloadRegistryState.restore_base_registry(state, plugin_status,
        loaded_at_ms: 123,
        reason: :plugin_config_hot_reload
      )

    assert restored.generation == 5
    assert restored.previous_registry == current_registry
    assert restored.registry == base_registry
    assert restored.base_registry == base_registry
    assert restored.sources.actions == %{{:session, :open} => :local}
    assert restored.plugin == plugin_status
    assert restored.loaded_at_ms == 123
    assert restored.reason == :plugin_config_hot_reload
  end

  test "uses current registry as base when no base registry exists" do
    current_registry = %{
      adapters: %{adapter: :module},
      renderers: %{renderer: :module},
      actions: %{{:session, :open} => :runtime_action}
    }

    state = %{generation: 0, registry: current_registry}

    restored =
      HotReloadRegistryState.restore_base_registry(state, nil,
        loaded_at_ms: 456,
        reason: :all_plugins_disabled
      )

    assert restored.generation == 1
    assert restored.previous_registry == current_registry
    assert restored.registry == current_registry
    assert restored.base_registry == current_registry

    assert restored.sources == %{
             adapters: %{adapter: :local},
             renderers: %{renderer: :local},
             actions: %{{:session, :open} => :local}
           }

    assert restored.plugin == nil
    assert restored.loaded_at_ms == 456
    assert restored.reason == :all_plugins_disabled
  end
end
