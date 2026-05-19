defmodule Ourocode.Plugin.ConfigSchema do
  @moduledoc """
  Parses plugin configuration files into the runtime plugin config model.

  This schema is intentionally smaller than the plugin loader. It preserves the
  user-configurable load intent, permissions, provenance, trust policy, and
  checksum data that the runtime can later pass to loader/reload boundaries.

  Optional plugin metadata is preserved when supplied. When omitted, runtime
  defaults are applied only for documented runtime fields: `enabled` defaults to
  `true`, `source` defaults to `third_party`, `provenance` and `metadata`
  default to empty maps, `transports` defaults to an empty list, and trust policy
  defaults to `official` for official plugins or `community_code` otherwise.
  Plugin entries also preserve whether trust policy was configured or defaulted
  from an absent config field.
  Plugin `settings` normalize to a JSON-safe string-keyed map and default to an
  empty map. Loader-only fields such as `expected_checksum`,
  `manifest_filename`, and `config` remain omitted as `nil`.
  """

  alias Ourocode.Json

  @official_plugin_id "ouroboros-plugin"
  @valid_sources MapSet.new(["official", "third_party", "local", "user"])
  @valid_trust_tiers MapSet.new(["official", "community_code", "community-code", "untrusted"])
  @required_permission_fields ["filesystem", "network", "process"]
  @valid_transport_types MapSet.new(["stdio", "sse", "streamable_http"])
  @package_identity_pattern ~r/^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?(?:\/[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?)*$/
  @semantic_version_pattern ~r/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/
  @metadata_key_pattern ~r/^[A-Za-z0-9_.-]+$/
  @elixir_module_pattern ~r/^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*$/

  defmodule PackageIdentity do
    @moduledoc """
    Typed package identity preserved from plugin configuration.
    """

    @enforce_keys [:id, :version]
    defstruct id: nil,
              name: nil,
              version: nil,
              publisher: nil,
              namespace: nil,
              package: nil

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t() | nil,
            version: String.t(),
            publisher: String.t() | nil,
            namespace: String.t() | nil,
            package: map() | nil
          }
  end

  defmodule PluginEntry do
    @moduledoc """
    Typed plugin configuration entry used by the runtime plugin loader.

    Raw configuration maps are still preserved for compatibility with loader
    and command-discovery code that needs original manifest fields.
    """

    @enforce_keys [
      :id,
      :identity,
      :package_identity,
      :path,
      :entrypoint,
      :enabled,
      :source,
      :provenance,
      :trust_policy,
      :trust_policy_state,
      :trust_evaluation,
      :permissions,
      :transports
    ]
    defstruct id: nil,
              identity: %{},
              package_identity: nil,
              path: nil,
              entrypoint: %{},
              enabled: true,
              source: "third_party",
              provenance: %{},
              trust_policy: %{},
              trust_policy_state: "absent_defaulted",
              trust_evaluation: %{},
              permissions: %{},
              transports: [],
              settings: %{},
              metadata: %{},
              expected_checksum: nil,
              manifest_filename: nil,
              config: nil

    @type t :: %__MODULE__{
            id: String.t(),
            identity: map(),
            package_identity: PackageIdentity.t(),
            path: String.t(),
            entrypoint: map(),
            enabled: boolean(),
            source: String.t(),
            provenance: map(),
            trust_policy: map(),
            trust_policy_state: String.t(),
            trust_evaluation: map(),
            permissions: %{required(String.t()) => [String.t()]},
            transports: [map()],
            settings: map(),
            metadata: map(),
            expected_checksum: String.t() | nil,
            manifest_filename: String.t() | nil,
            config: map() | nil
          }
  end

  @enforce_keys [:plugins]
  defstruct plugins: []

  @type permissions :: %{
          required(String.t()) => [String.t()]
        }

  @type plugin_entry :: PluginEntry.t()

  @type t :: %__MODULE__{
          plugins: [plugin_entry()]
        }

  @type parse_error ::
          :invalid_plugin_config_json
          | {:invalid_plugin_config_schema, String.t()}

  @doc """
  Parses a JSON plugin configuration file.
  """
  @spec parse_file(Path.t()) :: {:ok, t()} | {:error, parse_error()}
  def parse_file(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path) do
      parse(contents)
    else
      {:error, reason} -> {:error, {:invalid_plugin_config_schema, "cannot read file: #{reason}"}}
    end
  end

  @doc """
  Parses JSON plugin configuration contents.

  Supported input:

      {
        "plugins": [
          {
            "identity": {
              "id": "ouroboros-plugin",
              "name": "Ouroboros"
            },
            "path": "plugins/ouroboros",
            "entrypoint": {
              "type": "elixir_module",
              "module": "Ourocode.Plugin.Ouroboros"
            },
            "enabled": true,
            "source": "official",
            "expected_checksum": "...",
            "permissions": {
              "filesystem": [],
              "network": [],
              "process": []
            },
            "transports": [
              {"type": "stdio", "command": "bin/ouroboros-mcp"},
              {"type": "sse", "url": "http://localhost:4000/mcp/sse"},
              {"type": "streamable_http", "url": "http://localhost:4000/mcp"}
            ],
            "trust_policy": {"tier": "official"},
            "provenance": {"publisher": "ouroboros"}
          }
        ]
      }

  The canonical official plugin must use id `ouroboros-plugin`, source
  `official`, and trust tier `official`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, parse_error()}
  def parse(contents) when is_binary(contents) do
    with {:ok, decoded} <- Json.decode(contents),
         {:ok, plugins} <- parse_root(decoded) do
      {:ok, %__MODULE__{plugins: plugins}}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, {:invalid_plugin_config_schema, _message} = reason} -> {:error, reason}
      {:error, _reason} -> {:error, :invalid_plugin_config_json}
    end
  end

  @doc """
  Serializes a parsed plugin configuration into a JSON-safe map.

  The serialized shape keeps source metadata explicit for every plugin entry so
  plugin load, reload, and UI layers can display provenance without reaching
  into runtime-only structs.
  """
  @spec to_map(t() | PluginEntry.t()) :: map()
  def to_map(%__MODULE__{plugins: plugins}) do
    %{"plugins" => Enum.map(plugins, &plugin_entry_to_map/1)}
  end

  def to_map(%PluginEntry{} = entry) do
    plugin_entry_to_map(entry)
  end

  @doc """
  Serializes a parsed plugin configuration to JSON iodata.
  """
  @spec encode!(t()) :: iodata()
  def encode!(%__MODULE__{} = config) do
    config
    |> to_map()
    |> Json.encode!()
  end

  @doc """
  Saves a parsed plugin configuration as JSON.

  This is the config persistence boundary used by runtime/UI state transitions.
  It writes the same JSON-safe shape returned by `to_map/1`, including each
  plugin entry's current `enabled` boolean.
  """
  @spec save_file(t(), Path.t()) :: :ok | {:error, File.posix()}
  def save_file(%__MODULE__{} = config, path) when is_binary(path) do
    File.write(path, encode!(config))
  end

  @doc """
  Returns the source metadata projection for a plugin entry.
  """
  @spec source_metadata(PluginEntry.t()) :: map()
  def source_metadata(%PluginEntry{} = entry) do
    %{
      "id" => entry.id,
      "source" => entry.source,
      "provenance" => entry.provenance,
      "trust_policy" => entry.trust_policy,
      "trust_evaluation" => entry.trust_evaluation,
      "package_identity" => package_identity_to_map(entry.package_identity)
    }
  end

  defp parse_root(%{"plugins" => plugins}) when is_list(plugins) do
    plugins
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {plugin, index}, {:ok, acc} ->
      case parse_plugin(plugin, index) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} ->
        entries
        |> Enum.reverse()
        |> validate_unique_plugin_ids()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_root(%{"plugins" => _plugins}) do
    schema_error("plugins must be a list")
  end

  defp parse_root(_decoded) do
    schema_error("plugins list is required")
  end

  defp plugin_entry_to_map(%PluginEntry{} = entry) do
    %{
      "id" => entry.id,
      "identity" => entry.identity,
      "package_identity" => package_identity_to_map(entry.package_identity),
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
    |> maybe_put_string("expected_checksum", entry.expected_checksum)
    |> maybe_put_string("manifest_filename", entry.manifest_filename)
    |> maybe_put_string("config", entry.config)
  end

  defp package_identity_to_map(%PackageIdentity{} = package_identity) do
    %{
      "id" => package_identity.id,
      "name" => package_identity.name,
      "version" => package_identity.version,
      "publisher" => package_identity.publisher,
      "namespace" => package_identity.namespace,
      "package" => package_identity.package
    }
  end

  defp package_identity_to_map(nil), do: nil

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  defp parse_plugin(plugin, index) when is_map(plugin) do
    with {:ok, identity} <- parse_identity(plugin, index),
         {:ok, id} <- identity_id(identity, index),
         {:ok, source_metadata} <- parse_source_metadata(plugin, index),
         :ok <- validate_source_metadata_id(source_metadata, id, index),
         {:ok, plugin} <- apply_source_metadata_defaults(plugin, source_metadata, index),
         {:ok, package_identity} <- parse_package_identity(plugin, identity, index),
         {:ok, path} <- required_string(plugin, "path", index),
         {:ok, entrypoint} <- parse_entrypoint(plugin, index),
         {:ok, enabled} <- optional_boolean(plugin, "enabled", true, index),
         {:ok, source} <- optional_string(plugin, "source", "third_party", index),
         :ok <- validate_source(source, index),
         {:ok, provenance} <- optional_map(plugin, "provenance", %{}, index),
         {:ok, {trust_policy, trust_policy_state}} <- parse_trust_policy(plugin, source, index),
         :ok <- validate_official_identity(id, source, trust_policy, index),
         {:ok, trust_evaluation} <- evaluate_trust_policy(id, trust_policy, index),
         {:ok, permissions} <- parse_permissions(plugin, index),
         {:ok, transports} <- parse_transports(plugin, index),
         {:ok, settings} <- parse_settings(plugin, index),
         {:ok, optional_fields} <- optional_loader_fields(plugin, index) do
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

  defp parse_plugin(_plugin, index) do
    schema_error("plugins[#{index}] must be an object")
  end

  defp parse_source_metadata(plugin, index) do
    case Map.fetch(plugin, "source_metadata") do
      {:ok, source_metadata} when is_map(source_metadata) ->
        with :ok <- validate_optional_source_metadata_string(source_metadata, "id", index),
             :ok <- validate_optional_source_metadata_string(source_metadata, "source", index),
             :ok <- validate_optional_source_metadata_map(source_metadata, "provenance", index),
             :ok <- validate_optional_source_metadata_map(source_metadata, "trust_policy", index),
             :ok <-
               validate_optional_source_metadata_map(source_metadata, "package_identity", index) do
          {:ok, source_metadata}
        end

      :error ->
        {:ok, nil}

      _invalid ->
        schema_error("plugins[#{index}].source_metadata must be an object")
    end
  end

  defp validate_optional_source_metadata_string(nil, _key, _index), do: :ok

  defp validate_optional_source_metadata_string(source_metadata, key, index) do
    case Map.fetch(source_metadata, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        :ok

      :error ->
        :ok

      _invalid ->
        schema_error("plugins[#{index}].source_metadata.#{key} must be a non-empty string")
    end
  end

  defp validate_optional_source_metadata_map(nil, _key, _index), do: :ok

  defp validate_optional_source_metadata_map(source_metadata, key, index) do
    case Map.fetch(source_metadata, key) do
      {:ok, value} when is_map(value) ->
        :ok

      :error ->
        :ok

      _invalid ->
        schema_error("plugins[#{index}].source_metadata.#{key} must be an object")
    end
  end

  defp validate_source_metadata_id(nil, _id, _index), do: :ok

  defp validate_source_metadata_id(source_metadata, id, index) do
    case Map.get(source_metadata, "id") do
      nil ->
        :ok

      ^id ->
        :ok

      source_metadata_id ->
        schema_error(
          "plugins[#{index}].source_metadata.id must match identity.id: #{source_metadata_id}"
        )
    end
  end

  defp apply_source_metadata_defaults(plugin, nil, _index), do: {:ok, plugin}

  defp apply_source_metadata_defaults(plugin, source_metadata, index) do
    with {:ok, plugin} <- put_source_metadata_default(plugin, source_metadata, "source", index),
         {:ok, plugin} <-
           put_source_metadata_default(plugin, source_metadata, "provenance", index),
         {:ok, plugin} <-
           put_source_metadata_default(plugin, source_metadata, "trust_policy", index),
         {:ok, plugin} <- put_source_metadata_package_default(plugin, source_metadata) do
      {:ok, plugin}
    end
  end

  defp put_source_metadata_default(plugin, source_metadata, key, index) do
    case {Map.fetch(plugin, key), Map.fetch(source_metadata, key)} do
      {:error, {:ok, value}} ->
        {:ok, Map.put(plugin, key, value)}

      {{:ok, value}, {:ok, value}} ->
        {:ok, plugin}

      {{:ok, _plugin_value}, {:ok, _source_metadata_value}} ->
        schema_error("plugins[#{index}].source_metadata.#{key} must match #{key}")

      {_plugin_field, _source_metadata_field} ->
        {:ok, plugin}
    end
  end

  defp put_source_metadata_package_default(plugin, source_metadata) do
    case {Map.fetch(plugin, "package"), Map.fetch(source_metadata, "package_identity")} do
      {:error, {:ok, package_identity}} ->
        {:ok, Map.put(plugin, "package", package_identity_to_package_config(package_identity))}

      _existing_or_missing ->
        {:ok, plugin}
    end
  end

  defp package_identity_to_package_config(package_identity) do
    package_identity
    |> Map.take(["name", "version", "publisher", "namespace", "package"])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp validate_unique_plugin_ids(entries) do
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
        validate_package_identity(id, "identity.id", index)

      _missing_or_invalid ->
        schema_error("plugins[#{index}].identity.id must be a non-empty string")
    end
  end

  defp parse_package_identity(plugin, identity, index) do
    with {:ok, package} <- optional_map_field(plugin, "package", index),
         {:ok, name} <-
           first_optional_package_string(
             [
               {identity, "name", "identity.name"},
               {package, "name", "package.name"},
               {package, "package", "package.package"}
             ],
             index
           ),
         {:ok, version} <- package_version(plugin, identity, package, index) do
      with {:ok, publisher} <-
             first_optional_package_string(
               [
                 {identity, "publisher", "identity.publisher"},
                 {package, "publisher", "package.publisher"}
               ],
               index
             ),
           {:ok, namespace} <-
             first_optional_package_string(
               [
                 {identity, "namespace", "identity.namespace"},
                 {package, "namespace", "package.namespace"}
               ],
               index
             ) do
        {:ok,
         %PackageIdentity{
           id: Map.fetch!(identity, "id"),
           name: name,
           version: version,
           publisher: publisher,
           namespace: namespace,
           package: package
         }}
      end
    end
  end

  defp first_optional_package_string(candidates, index) do
    Enum.reduce_while(candidates, {:ok, nil}, fn {map, key, label}, {:ok, nil} ->
      case optional_package_string(map, key, label, index) do
        {:ok, nil} -> {:cont, {:ok, nil}}
        {:ok, value} -> {:halt, {:ok, value}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp optional_package_string(nil, _key, _label, _index), do: {:ok, nil}

  defp optional_package_string(map, key, label, index) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        validate_package_field(value, label, index)

      :error ->
        {:ok, nil}

      _invalid ->
        schema_error("plugins[#{index}].#{label} must be a non-empty string")
    end
  end

  defp package_version(plugin, identity, package, index) do
    with {:ok, config_version} <- optional_package_string(plugin, "version", "version", index),
         {:ok, identity_version} <-
           optional_package_string(identity, "version", "identity.version", index),
         {:ok, package_version} <-
           optional_package_string(package, "version", "package.version", index) do
      case config_version || identity_version || package_version do
        nil ->
          schema_error(
            "plugins[#{index}].version is required; set version, identity.version, or package.version to a non-empty string"
          )

        version ->
          validate_semantic_version(version, index)
      end
    end
  end

  defp parse_entrypoint(plugin, index) do
    case Map.fetch(plugin, "entrypoint") do
      {:ok, entrypoint} when is_map(entrypoint) ->
        with {:ok, type} <- required_nested_string(entrypoint, "entrypoint", "type", index),
             :ok <- validate_entrypoint_target(entrypoint, type, index) do
          {:ok, entrypoint}
        end

      _missing_or_invalid ->
        schema_error("plugins[#{index}].entrypoint must be an object")
    end
  end

  defp validate_entrypoint_target(entrypoint, "elixir_module", index) do
    case required_nested_string(entrypoint, "entrypoint", "module", index) do
      {:ok, module} -> validate_entrypoint_module(module, index)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_entrypoint_target(entrypoint, "executable", index) do
    case required_nested_string(entrypoint, "entrypoint", "command", index) do
      {:ok, command} -> validate_entrypoint_command(command, index)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_entrypoint_target(entrypoint, "manifest", index) do
    case required_nested_string(entrypoint, "entrypoint", "path", index) do
      {:ok, path} -> validate_entrypoint_path(path, "entrypoint.path", index)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_entrypoint_target(_entrypoint, type, index) do
    schema_error("plugins[#{index}].entrypoint.type is unsupported: #{type}")
  end

  defp parse_trust_policy(plugin, source, index) do
    default_tier =
      case source do
        "official" -> "official"
        _source -> "community_code"
      end

    {policy, trust_policy_state} =
      case Map.fetch(plugin, "trust_policy") do
        {:ok, configured_policy} -> {configured_policy, "configured"}
        :error -> {%{"tier" => default_tier}, "absent_defaulted"}
      end

    case policy do
      policy when is_map(policy) ->
        tier = Map.get(policy, "tier", Map.get(policy, "trust_tier", default_tier))

        cond do
          not is_binary(tier) ->
            schema_error("plugins[#{index}].trust_policy.tier must be a string")

          not MapSet.member?(@valid_trust_tiers, tier) ->
            schema_error("plugins[#{index}].trust_policy.tier is unsupported")

          true ->
            {:ok,
             {policy
              |> Map.put("tier", tier)
              |> Map.put_new("requires_explicit_approval", tier != "official"),
              trust_policy_state}}
        end

      _policy ->
        schema_error("plugins[#{index}].trust_policy must be an object")
    end
  end

  defp validate_official_identity(
         @official_plugin_id,
         "official",
         %{"tier" => "official"},
         _index
       ) do
    :ok
  end

  defp validate_official_identity(@official_plugin_id, "official", trust_policy, index) do
    schema_error(
      "plugins[#{index}] official plugin must use trust tier official, got #{trust_policy["tier"]}"
    )
  end

  defp validate_official_identity(id, "official", _trust_policy, index) do
    schema_error("plugins[#{index}] official plugin must be #{@official_plugin_id}, got #{id}")
  end

  defp validate_official_identity(@official_plugin_id, _source, _trust_policy, index) do
    schema_error("plugins[#{index}] #{@official_plugin_id} must use source official")
  end

  defp validate_official_identity(_id, _source, _trust_policy, _index), do: :ok

  defp evaluate_trust_policy(id, %{"tier" => tier} = trust_policy, _index) do
    manifest = %{
      "plugin" => %{
        "id" => id,
        "trust_tier" => tier
      }
    }

    trust_result =
      manifest
      |> Ourocode.Plugin.TrustPolicy.classify()
      |> atom_keys_to_strings()
      |> Map.put("requires_explicit_approval", trust_policy["requires_explicit_approval"])

    {:ok, trust_result}
  end

  defp atom_keys_to_strings(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp validate_source(source, index) do
    if MapSet.member?(@valid_sources, source) do
      :ok
    else
      schema_error("plugins[#{index}].source is unsupported")
    end
  end

  defp parse_permissions(plugin, index) do
    case Map.fetch(plugin, "permissions") do
      {:ok, permissions} when is_map(permissions) ->
        with :ok <- require_permission_fields(permissions, index),
             :ok <- validate_permission_fields(permissions, index) do
          {:ok, permissions}
        end

      _missing_or_invalid ->
        schema_error("plugins[#{index}].permissions must be an object")
    end
  end

  defp require_permission_fields(permissions, index) do
    case Enum.find(@required_permission_fields, &(not Map.has_key?(permissions, &1))) do
      nil -> :ok
      missing -> schema_error("plugins[#{index}].permissions.#{missing} is required")
    end
  end

  defp validate_permission_fields(permissions, index) do
    Enum.reduce_while(@required_permission_fields, :ok, fn field, :ok ->
      case Map.fetch!(permissions, field) do
        values when is_list(values) ->
          if Enum.all?(values, &valid_permission_value?/1) do
            {:cont, :ok}
          else
            {:halt,
             schema_error(
               "plugins[#{index}].permissions.#{field} must be a list of non-empty strings"
             )}
          end

        _invalid ->
          {:halt,
           schema_error(
             "plugins[#{index}].permissions.#{field} must be a list of non-empty strings"
           )}
      end
    end)
  end

  defp parse_transports(plugin, index) do
    case Map.fetch(plugin, "transports") do
      {:ok, transports} when is_list(transports) ->
        transports
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {transport, transport_index}, {:ok, acc} ->
          case parse_transport(transport, index, transport_index) do
            {:ok, parsed_transport} -> {:cont, {:ok, [parsed_transport | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, parsed_transports} -> {:ok, Enum.reverse(parsed_transports)}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:ok, []}

      _invalid ->
        schema_error("plugins[#{index}].transports must be a list")
    end
  end

  defp parse_transport(transport, plugin_index, transport_index) when is_map(transport) do
    parent_key = "transports[#{transport_index}]"

    with {:ok, type} <- required_nested_string(transport, parent_key, "type", plugin_index),
         :ok <- validate_transport_type(type, plugin_index, transport_index),
         :ok <- validate_transport_required_fields(transport, type, plugin_index, transport_index) do
      {:ok, transport}
    end
  end

  defp parse_transport(_transport, plugin_index, transport_index) do
    schema_error("plugins[#{plugin_index}].transports[#{transport_index}] must be an object")
  end

  defp validate_transport_type(type, plugin_index, transport_index) do
    if MapSet.member?(@valid_transport_types, type) do
      :ok
    else
      supported_types =
        @valid_transport_types
        |> MapSet.to_list()
        |> Enum.sort()
        |> Enum.join(", ")

      schema_error(
        "plugins[#{plugin_index}].transports[#{transport_index}].type is unsupported: #{type}; supported MCP transports are #{supported_types}"
      )
    end
  end

  defp validate_transport_required_fields(transport, "stdio", plugin_index, transport_index) do
    require_transport_string(transport, "command", plugin_index, transport_index)
  end

  defp validate_transport_required_fields(transport, type, plugin_index, transport_index)
       when type in ["sse", "streamable_http"] do
    require_transport_string(transport, "url", plugin_index, transport_index)
  end

  defp require_transport_string(transport, key, plugin_index, transport_index) do
    case Map.fetch(transport, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        :ok

      _missing_or_invalid ->
        schema_error(
          "plugins[#{plugin_index}].transports[#{transport_index}].#{key} must be a non-empty string"
        )
    end
  end

  defp parse_settings(plugin, index) do
    case Map.fetch(plugin, "settings") do
      {:ok, settings} when is_map(settings) ->
        normalize_settings(settings, "plugins[#{index}].settings")

      :error ->
        {:ok, %{}}

      _invalid ->
        schema_error("plugins[#{index}].settings must be an object")
    end
  end

  defp normalize_settings(settings, path) when is_map(settings) do
    settings
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      cond do
        not valid_setting_key?(key) ->
          {:halt, schema_error("#{path} keys must be non-empty strings")}

        Map.has_key?(acc, key) ->
          {:halt, schema_error("#{path}.#{key} is duplicated after normalization")}

        true ->
          case normalize_setting_value(value, "#{path}.#{key}") do
            {:ok, normalized_value} -> {:cont, {:ok, Map.put(acc, key, normalized_value)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp normalize_setting_value(value, _path) when is_binary(value), do: {:ok, value}
  defp normalize_setting_value(value, _path) when is_boolean(value), do: {:ok, value}
  defp normalize_setting_value(value, _path) when is_number(value), do: {:ok, value}
  defp normalize_setting_value(nil, _path), do: {:ok, nil}

  defp normalize_setting_value(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case normalize_setting_value(value, "#{path}[#{index}]") do
        {:ok, normalized_value} -> {:cont, {:ok, [normalized_value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized_values} -> {:ok, Enum.reverse(normalized_values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_setting_value(value, path) when is_map(value) do
    normalize_settings(value, path)
  end

  defp normalize_setting_value(_value, path) do
    schema_error(
      "#{path} must be a JSON-safe setting value: string, number, boolean, null, list, or object"
    )
  end

  defp optional_loader_fields(plugin, index) do
    with {:ok, expected_checksum} <- optional_string_field(plugin, "expected_checksum", index),
         {:ok, manifest_filename} <- optional_string_field(plugin, "manifest_filename", index),
         {:ok, metadata} <- optional_map_field(plugin, "metadata", index),
         :ok <- validate_metadata(metadata || %{}, index),
         {:ok, config} <- optional_map_field(plugin, "config", index) do
      fields =
        %{}
        |> maybe_put(:expected_checksum, expected_checksum)
        |> maybe_put(:manifest_filename, manifest_filename)
        |> maybe_put(:metadata, metadata || %{})
        |> maybe_put(:config, config)

      {:ok, fields}
    end
  end

  defp optional_string_field(plugin, key, index) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      :error ->
        {:ok, nil}

      _invalid ->
        schema_error("plugins[#{index}].#{key} must be a non-empty string")
    end
  end

  defp optional_map_field(plugin, key, index) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_map(value) ->
        {:ok, value}

      :error ->
        {:ok, nil}

      _invalid ->
        schema_error("plugins[#{index}].#{key} must be an object")
    end
  end

  defp maybe_put(fields, _key, nil), do: fields
  defp maybe_put(fields, key, value), do: Map.put(fields, key, value)

  defp required_string(plugin, key, index) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      _missing_or_invalid ->
        schema_error("plugins[#{index}].#{key} must be a non-empty string")
    end
  end

  defp required_nested_string(plugin, parent_key, key, index) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      _missing_or_invalid ->
        schema_error("plugins[#{index}].#{parent_key}.#{key} must be a non-empty string")
    end
  end

  defp optional_string(plugin, key, default, index) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      :error ->
        {:ok, default}

      _invalid ->
        schema_error("plugins[#{index}].#{key} must be a non-empty string")
    end
  end

  defp optional_boolean(plugin, key, default, index) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      :error -> {:ok, default}
      _invalid -> schema_error("plugins[#{index}].#{key} must be a boolean")
    end
  end

  defp optional_map(plugin, key, default, index) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      :error -> {:ok, default}
      _invalid -> schema_error("plugins[#{index}].#{key} must be an object")
    end
  end

  defp schema_error(message) do
    {:error, {:invalid_plugin_config_schema, message}}
  end

  defp validate_package_field(value, "package.name" = label, index) do
    validate_package_identity(value, label, index)
  end

  defp validate_package_field(value, "package.package" = label, index) do
    validate_package_identity(value, label, index)
  end

  defp validate_package_field(value, "identity.namespace" = label, index) do
    validate_package_identity(value, label, index)
  end

  defp validate_package_field(value, "package.namespace" = label, index) do
    validate_package_identity(value, label, index)
  end

  defp validate_package_field(value, _label, _index), do: {:ok, value}

  defp validate_package_identity("@" <> scoped_name = value, label, index) do
    case String.split(scoped_name, "/", parts: 2) do
      [scope, package] when scope != "" and package != "" ->
        if valid_package_segment?(scope) and valid_package_segment?(package) do
          {:ok, value}
        else
          invalid_package_identity(label, index)
        end

      _invalid ->
        invalid_package_identity(label, index)
    end
  end

  defp validate_package_identity(value, label, index) do
    if Regex.match?(@package_identity_pattern, value) do
      {:ok, value}
    else
      invalid_package_identity(label, index)
    end
  end

  defp valid_package_segment?(segment), do: Regex.match?(@package_identity_pattern, segment)

  defp invalid_package_identity(label, index) do
    schema_error("plugins[#{index}].#{label} must use package identity format")
  end

  defp validate_semantic_version(version, index) do
    if Regex.match?(@semantic_version_pattern, version) do
      {:ok, version}
    else
      schema_error("plugins[#{index}].version must be a semantic version")
    end
  end

  defp validate_entrypoint_command(command, index) do
    cond do
      String.trim(command) != command ->
        schema_error(
          "plugins[#{index}].entrypoint.command must not contain surrounding whitespace"
        )

      String.contains?(command, ["\0", "\n", "\r"]) ->
        schema_error("plugins[#{index}].entrypoint.command must be a single command string")

      String.contains?(command, [" ", "\t"]) ->
        schema_error("plugins[#{index}].entrypoint.command must not include arguments")

      Path.type(command) == :absolute ->
        schema_error("plugins[#{index}].entrypoint.command must be a relative command")

      path_traverses?(command) ->
        schema_error(
          "plugins[#{index}].entrypoint.command must be a relative command inside the plugin"
        )

      true ->
        :ok
    end
  end

  defp validate_entrypoint_module(module, index) do
    if Regex.match?(@elixir_module_pattern, module) do
      :ok
    else
      schema_error("plugins[#{index}].entrypoint.module must be an Elixir module name")
    end
  end

  defp validate_entrypoint_path(path, label, index) do
    cond do
      String.trim(path) != path ->
        schema_error("plugins[#{index}].#{label} must not contain surrounding whitespace")

      String.contains?(path, ["\0", "\n", "\r"]) ->
        schema_error("plugins[#{index}].#{label} must be a single relative path")

      Path.type(path) == :absolute or path_traverses?(path) ->
        schema_error("plugins[#{index}].#{label} must be a relative path inside the plugin")

      true ->
        :ok
    end
  end

  defp path_traverses?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
  end

  defp valid_permission_value?(value) when is_binary(value) and value != "" do
    String.trim(value) == value and not String.contains?(value, ["\0", "\n", "\r"])
  end

  defp valid_permission_value?(_value), do: false

  defp validate_metadata(metadata, index) do
    Enum.reduce_while(metadata, :ok, fn {key, value}, :ok ->
      cond do
        not is_binary(key) or key == "" or not Regex.match?(@metadata_key_pattern, key) ->
          {:halt, schema_error("plugins[#{index}].metadata keys must be non-empty strings")}

        valid_metadata_value?(value) ->
          {:cont, :ok}

        true ->
          {:halt,
           schema_error(
             "plugins[#{index}].metadata.#{key} must be a string, number, boolean, null, or list of strings"
           )}
      end
    end)
  end

  defp valid_metadata_value?(value) when is_binary(value), do: true
  defp valid_metadata_value?(value) when is_boolean(value), do: true
  defp valid_metadata_value?(value) when is_number(value), do: true
  defp valid_metadata_value?(nil), do: true

  defp valid_metadata_value?(values) when is_list(values) do
    Enum.all?(values, &(is_binary(&1) and &1 != ""))
  end

  defp valid_metadata_value?(_value), do: false

  defp valid_setting_key?(key) when is_binary(key) and key != "" do
    String.trim(key) == key and not String.contains?(key, ["\0", "\n", "\r"])
  end

  defp valid_setting_key?(_key), do: false
end
