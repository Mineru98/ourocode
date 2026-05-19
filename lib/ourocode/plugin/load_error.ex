defmodule Ourocode.Plugin.LoadError do
  @moduledoc """
  Structured plugin load failure returned by the plugin loader.
  """

  defexception [:reason, :plugin_path, :manifest_path, :message]

  @type t :: %__MODULE__{
          reason: atom(),
          plugin_path: String.t() | nil,
          manifest_path: String.t() | nil,
          message: String.t()
        }

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    plugin_path = Keyword.get(opts, :plugin_path)
    manifest_path = Keyword.get(opts, :manifest_path)

    %__MODULE__{
      reason: reason,
      plugin_path: plugin_path,
      manifest_path: manifest_path,
      message: message(reason, plugin_path, manifest_path)
    }
  end

  defp message(:missing_capability_manifest, plugin_path, manifest_path) do
    "plugin #{inspect(plugin_path)} is missing required capability manifest at #{inspect(manifest_path)}"
  end

  defp message(:invalid_capability_manifest_schema, plugin_path, manifest_path) do
    "plugin #{inspect(plugin_path)} has an invalid capability manifest schema at #{inspect(manifest_path)}"
  end

  defp message(:plugin_checksum_mismatch, plugin_path, manifest_path) do
    "plugin #{inspect(plugin_path)} checksum does not match expected value at #{inspect(manifest_path)}"
  end

  defp message(:missing_plugin_checksum, plugin_path, manifest_path) do
    "plugin #{inspect(plugin_path)} is missing required expected checksum at #{inspect(manifest_path)}"
  end

  defp message(:plugin_checksum_unavailable, plugin_path, manifest_path) do
    "plugin #{inspect(plugin_path)} checksum could not be computed at #{inspect(manifest_path)}"
  end

  defp message(:missing_community_plugin_trust_approval, plugin_path, manifest_path) do
    "community-code plugin #{inspect(plugin_path)} is missing an explicit trusted approval record at #{inspect(manifest_path)}"
  end

  defp message(:revoked_community_plugin_trust_approval, plugin_path, manifest_path) do
    "community-code plugin #{inspect(plugin_path)} has a revoked trusted approval record at #{inspect(manifest_path)}"
  end

  defp message(:invalid_plugin_trust_approvals, plugin_path, manifest_path) do
    "plugin #{inspect(plugin_path)} has invalid trusted approval records at #{inspect(manifest_path)}"
  end

  defp message(:untrusted_plugin_identity, plugin_path, manifest_path) do
    "plugin #{inspect(plugin_path)} has an untrusted identity at #{inspect(manifest_path)}"
  end

  defp message(reason, plugin_path, manifest_path) do
    "plugin #{inspect(plugin_path)} failed to load with #{inspect(reason)} at #{inspect(manifest_path)}"
  end
end
