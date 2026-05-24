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
  alias Ourocode.Plugin.ConfigRoot
  alias Ourocode.Plugin.ConfigSerialization

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
         {:ok, plugins} <- ConfigRoot.parse(decoded) do
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
  def to_map(config_or_entry), do: ConfigSerialization.to_map(config_or_entry)

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
  def source_metadata(%PluginEntry{} = entry), do: ConfigSerialization.source_metadata(entry)
end
