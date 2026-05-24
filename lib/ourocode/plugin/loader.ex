defmodule Ourocode.Plugin.Loader do
  @moduledoc """
  Validates plugin load prerequisites before any strategy is installed.

  MVP plugin security starts with an allowed-path policy and a required
  capability manifest. Later checks such as trust tiers, checksums, and
  journaled switch/rollback can build on this boundary without allowing
  partially loaded plugins.
  """

  alias Ourocode.Json
  alias Ourocode.Plugin.Checksum
  alias Ourocode.Plugin.ConfigStatus
  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.LoadError
  alias Ourocode.Plugin.PathPolicy
  alias Ourocode.Plugin.TrustPolicy

  @capability_manifest_filename "capabilities.json"

  @type loaded_plugin :: %{
          required(:plugin_path) => String.t(),
          required(:capability_manifest_path) => String.t(),
          required(:capability_manifest) => map(),
          required(:checksum) => String.t(),
          required(:trust_tier) => String.t(),
          required(:trust_classification) => String.t(),
          optional(:plugin_id) => String.t(),
          optional(:trust_approval) => map()
        }

  @type config_status_record :: %{
          required(:plugin_id) => String.t(),
          required(:source_type) => String.t(),
          required(:version) => String.t(),
          required(:enabled?) => boolean(),
          required(:load_state) => :load_requested | :disabled,
          required(:path) => String.t()
        }

  @type config_load_report :: %{
          required(:status) => :ready,
          required(:plugins) => [config_status_record()],
          required(:enabled_official_plugins) => [config_status_record()],
          required(:enabled_third_party_plugins) => [config_status_record()]
        }

  @doc """
  Parses a plugin configuration file and returns normalized load status records.

  This is intentionally a configuration/status projection, not a strategy load.
  Enabled official and third-party plugin definitions are made visible through
  dedicated status lists so terminal status panes can show the user's load
  intent before a hot-reload boundary validates manifests, checksums, and
  mappings.
  """
  @spec load_config_file(Path.t()) ::
          {:ok, config_load_report()} | {:error, ConfigSchema.parse_error()}
  defdelegate load_config_file(path), to: ConfigStatus, as: :load_file

  @doc """
  Returns normalized plugin status records for a parsed plugin configuration.
  """
  @spec config_status_report(ConfigSchema.t()) :: config_load_report()
  defdelegate config_status_report(config), to: ConfigStatus, as: :report

  @doc """
  Normalizes a parsed plugin entry into the status shape used by UI/runtime panes.
  """
  @spec config_status_record(ConfigSchema.PluginEntry.t()) :: config_status_record()
  defdelegate config_status_record(plugin), to: ConfigStatus, as: :record

  @doc """
  Loads a plugin only after validating that its path is allowed, its capability
  manifest exists, that manifest matches the MVP schema, and an expected
  checksum is supplied and matches the computed plugin checksum. Community-code
  plugins additionally require an explicit trusted approval record.
  """
  @spec load(Path.t(), keyword()) :: {:ok, loaded_plugin()} | {:error, LoadError.t()}
  def load(plugin_path, opts \\ []) when is_binary(plugin_path) and is_list(opts) do
    with {:ok, expanded_plugin_path} <- PathPolicy.validate(plugin_path, opts) do
      load_allowed_plugin(expanded_plugin_path, opts)
    else
      {:error, reason} ->
        {:error,
         LoadError.exception(
           reason: reason,
           plugin_path: plugin_path,
           manifest_path: nil
         )}
    end
  end

  defp load_allowed_plugin(plugin_path, opts) do
    manifest_path = capability_manifest_path(plugin_path, opts)

    case File.regular?(manifest_path) do
      true ->
        with {:ok, capability_manifest} <- validate_capability_manifest(manifest_path),
             {:ok, checksum} <- verify_checksum(plugin_path, opts),
             {:ok, trust_result} <-
               TrustPolicy.validate(capability_manifest, plugin_path, checksum, opts) do
          {:ok,
           Map.merge(
             %{
               plugin_path: plugin_path,
               capability_manifest_path: manifest_path,
               capability_manifest: capability_manifest,
               checksum: checksum
             },
             trust_result
           )}
        else
          {:error, reason} ->
            {:error,
             LoadError.exception(
               reason: reason,
               plugin_path: plugin_path,
               manifest_path: manifest_path
             )}
        end

      false ->
        {:error,
         LoadError.exception(
           reason: :missing_capability_manifest,
           plugin_path: plugin_path,
           manifest_path: manifest_path
         )}
    end
  end

  @doc """
  Validates and returns a parsed capability manifest.
  """
  @spec validate_capability_manifest(Path.t()) ::
          {:ok, map()}
          | {:error, :invalid_capability_manifest_json | :invalid_capability_manifest_schema}
  def validate_capability_manifest(manifest_path) when is_binary(manifest_path) do
    with {:ok, contents} <- File.read(manifest_path),
         {:ok, manifest} <- Json.decode(contents),
         :ok <- validate_capability_manifest_schema(manifest) do
      {:ok, manifest}
    else
      {:error, _reason} -> {:error, :invalid_capability_manifest_json}
      :error -> {:error, :invalid_capability_manifest_schema}
    end
  end

  defp validate_capability_manifest_schema(%{"capabilities" => capabilities})
       when is_list(capabilities) do
    if Enum.all?(capabilities, &is_binary/1) do
      :ok
    else
      :error
    end
  end

  defp validate_capability_manifest_schema(_manifest), do: :error

  @doc """
  Returns the required capability manifest path for a plugin directory.
  """
  @spec capability_manifest_path(Path.t(), keyword()) :: String.t()
  def capability_manifest_path(plugin_path, opts \\ []) when is_binary(plugin_path) do
    manifest_filename = Keyword.get(opts, :manifest_filename, @capability_manifest_filename)
    Path.join(plugin_path, manifest_filename)
  end

  @doc """
  Computes the deterministic SHA-256 checksum for a plugin directory.

  The checksum is path-stable across machines because only paths relative to
  the plugin root and file bytes are included.
  """
  @spec checksum(Path.t()) :: {:ok, String.t()} | {:error, :plugin_checksum_unavailable}
  def checksum(plugin_path) when is_binary(plugin_path) do
    Checksum.compute(plugin_path)
  end

  defp verify_checksum(plugin_path, opts) do
    expected_checksum = Keyword.get(opts, :expected_checksum)

    if is_nil(expected_checksum) do
      {:error, :missing_plugin_checksum}
    else
      with {:ok, computed_checksum} <- Checksum.compute(plugin_path) do
        if computed_checksum == expected_checksum do
          {:ok, computed_checksum}
        else
          {:error, :plugin_checksum_mismatch}
        end
      end
    end
  end
end
