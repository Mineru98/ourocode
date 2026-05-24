defmodule Ourocode.Plugin.HotReloadTransitionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.HotReloadTransition

  test "builds deterministic transitions for added, changed, preserved, and removed plugins" do
    previous = %{
      plugins_by_id: %{
        "alpha" => plugin("alpha", :enabled, true),
        "beta" => plugin("beta", :disabled, false),
        "delta" => plugin("delta", :load_failed, true),
        "removed" => plugin("removed", :enabled, true)
      }
    }

    next = %{
      plugins_by_id: %{
        "alpha" => plugin("alpha", :enabled, true),
        "beta" => plugin("beta", :enabled, true),
        "delta" => plugin("delta", :disabled, false),
        "gamma" => plugin("gamma", :disabled, false)
      }
    }

    assert HotReloadTransition.build(previous, next) == [
             %{
               plugin_id: "alpha",
               from: :enabled,
               to: :enabled,
               action: :keep_loaded,
               loadable?: true,
               reason: :enabled_preserved
             },
             %{
               plugin_id: "beta",
               from: :disabled,
               to: :enabled,
               action: :load_requested,
               loadable?: true,
               reason: :enabled_in_config
             },
             %{
               plugin_id: "delta",
               from: :load_failed,
               to: :disabled,
               action: :skip_load,
               loadable?: false,
               reason: :disabled_in_config
             },
             %{
               plugin_id: "gamma",
               from: :unconfigured,
               to: :disabled,
               action: :skip_load,
               loadable?: false,
               reason: :disabled_in_config
             },
             %{
               plugin_id: "removed",
               from: :enabled,
               to: :unconfigured,
               action: :unload_requested,
               loadable?: false,
               reason: :removed_from_config
             }
           ]
  end

  test "marks only the matching plugin transition as load failed" do
    failure = %{reason: :missing_capability_manifest}

    transitions = [
      %{
        plugin_id: "alpha",
        from: :unconfigured,
        to: :enabled,
        action: :load_requested,
        loadable?: true,
        reason: :enabled_in_config
      },
      %{
        plugin_id: "beta",
        from: :unconfigured,
        to: :enabled,
        action: :load_requested,
        loadable?: true,
        reason: :enabled_in_config
      }
    ]

    assert HotReloadTransition.mark_load_failed(transitions, "beta", failure) == [
             %{
               plugin_id: "alpha",
               from: :unconfigured,
               to: :enabled,
               action: :load_requested,
               loadable?: true,
               reason: :enabled_in_config
             },
             %{
               plugin_id: "beta",
               from: :unconfigured,
               to: :load_failed,
               action: :load_failed,
               loadable?: false,
               reason: :missing_capability_manifest,
               load_error: failure
             }
           ]
  end

  defp plugin(id, state, enabled?) do
    %{id: id, state: state, enabled?: enabled?}
  end
end
