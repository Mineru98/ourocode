defmodule Ourocode.Plugin.ConfigSerialization do
  @moduledoc """
  JSON-safe projections for parsed plugin configuration structs.
  """

  alias Ourocode.Plugin.ConfigPackageIdentity
  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.ConfigSchema.PluginEntry

  @spec to_map(ConfigSchema.t() | PluginEntry.t()) :: map()
  def to_map(%ConfigSchema{plugins: plugins}) do
    %{"plugins" => Enum.map(plugins, &plugin_entry_to_map/1)}
  end

  def to_map(%PluginEntry{} = entry) do
    plugin_entry_to_map(entry)
  end

  @spec source_metadata(PluginEntry.t()) :: map()
  def source_metadata(%PluginEntry{} = entry) do
    %{
      "id" => entry.id,
      "source" => entry.source,
      "provenance" => entry.provenance,
      "trust_policy" => entry.trust_policy,
      "trust_evaluation" => entry.trust_evaluation,
      "package_identity" => ConfigPackageIdentity.to_map(entry.package_identity)
    }
  end

  defp plugin_entry_to_map(%PluginEntry{} = entry) do
    %{
      "id" => entry.id,
      "identity" => entry.identity,
      "package_identity" => ConfigPackageIdentity.to_map(entry.package_identity),
      "path" => entry.path,
      "entrypoint" => entry.entrypoint,
      "enabled" => entry.enabled,
      "source" => entry.source,
      "source_metadata" => source_metadata(entry),
      "provenance" => entry.provenance,
      "trust_policy" => entry.trust_policy,
      "trust_policy_state" => entry.trust_policy_state,
      "trust_evaluation" => entry.trust_evaluation,
      "permissions" => entry.permissions,
      "transports" => entry.transports,
      "settings" => entry.settings,
      "metadata" => entry.metadata
    }
    |> maybe_put("expected_checksum", entry.expected_checksum)
    |> maybe_put("manifest_filename", entry.manifest_filename)
    |> maybe_put("config", entry.config)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
