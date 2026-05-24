defmodule Ourocode.Plugin.ConfigPluginEntry do
  @moduledoc false

  alias Ourocode.Plugin.ConfigEntrypoint
  alias Ourocode.Plugin.ConfigFields
  alias Ourocode.Plugin.ConfigLoaderFields
  alias Ourocode.Plugin.ConfigPackageIdentity
  alias Ourocode.Plugin.ConfigPermissions
  alias Ourocode.Plugin.ConfigSchema.PluginEntry
  alias Ourocode.Plugin.ConfigSourceMetadata
  alias Ourocode.Plugin.ConfigTransport
  alias Ourocode.Plugin.ConfigTrustPolicy

  @spec parse(term(), non_neg_integer()) ::
          {:ok, PluginEntry.t()} | {:error, {:invalid_plugin_config_schema, String.t()}}
  def parse(plugin, index) when is_map(plugin) do
    with {:ok, identity} <- parse_identity(plugin, index),
         {:ok, id} <- identity_id(identity, index),
         {:ok, source_metadata} <- ConfigSourceMetadata.parse(plugin, index),
         :ok <- ConfigSourceMetadata.validate_id(source_metadata, id, index),
         {:ok, plugin} <- ConfigSourceMetadata.apply_defaults(plugin, source_metadata, index),
         {:ok, package_identity} <- ConfigPackageIdentity.parse(plugin, identity, index),
         {:ok, path} <- ConfigFields.required_string(plugin, "path", index),
         {:ok, entrypoint} <- ConfigEntrypoint.parse(plugin, index),
         {:ok, enabled} <- ConfigFields.optional_boolean(plugin, "enabled", true, index),
         {:ok, source} <- ConfigFields.optional_string(plugin, "source", "third_party", index),
         :ok <- ConfigFields.validate_source(source, index),
         {:ok, provenance} <- ConfigFields.optional_map(plugin, "provenance", %{}, index),
         {:ok, {trust_policy, trust_policy_state}} <-
           ConfigTrustPolicy.parse(plugin, source, index),
         :ok <- ConfigTrustPolicy.validate_official_identity(id, source, trust_policy, index),
         {:ok, trust_evaluation} <- ConfigTrustPolicy.evaluate(id, trust_policy, index),
         {:ok, permissions} <- ConfigPermissions.parse(plugin, index),
         {:ok, transports} <- ConfigTransport.parse(plugin, index),
         {:ok, settings} <- ConfigFields.parse_settings(plugin, index),
         {:ok, optional_fields} <- ConfigLoaderFields.parse(plugin, index) do
      entry = %PluginEntry{
        id: id,
        identity: identity,
        package_identity: package_identity,
        path: path,
        entrypoint: entrypoint,
        enabled: enabled,
        source: source,
        provenance: provenance,
        trust_policy: trust_policy,
        trust_policy_state: trust_policy_state,
        trust_evaluation: trust_evaluation,
        permissions: permissions,
        transports: transports,
        settings: settings
      }

      {:ok, struct(entry, optional_fields)}
    end
  end

  def parse(_plugin, index) do
    schema_error("plugins[#{index}] must be an object")
  end

  @spec validate_unique_ids([PluginEntry.t()]) ::
          {:ok, [PluginEntry.t()]} | {:error, {:invalid_plugin_config_schema, String.t()}}
  def validate_unique_ids(entries) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(%{}, fn {entry, index}, seen ->
      case Map.fetch(seen, entry.id) do
        {:ok, first_index} ->
          {:halt,
           schema_error(
             "plugins[#{index}].identity.id duplicates plugins[#{first_index}].identity.id: #{entry.id}"
           )}

        :error ->
          {:cont, Map.put(seen, entry.id, index)}
      end
    end)
    |> case do
      seen when is_map(seen) -> {:ok, entries}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_identity(plugin, index) do
    case Map.fetch(plugin, "identity") do
      {:ok, identity} when is_map(identity) ->
        with {:ok, _id} <- identity_id(identity, index) do
          {:ok, identity}
        end

      _missing_or_invalid ->
        schema_error("plugins[#{index}].identity must be an object with non-empty id")
    end
  end

  defp identity_id(identity, index) do
    case Map.fetch(identity, "id") do
      {:ok, id} when is_binary(id) and id != "" ->
        ConfigPackageIdentity.validate_identity(id, "identity.id", index)

      _missing_or_invalid ->
        schema_error("plugins[#{index}].identity.id must be a non-empty string")
    end
  end

  defp schema_error(message) do
    {:error, {:invalid_plugin_config_schema, message}}
  end
end
