defmodule Ourocode.Plugin.Loader do
  @moduledoc """
  Validates plugin load prerequisites before any strategy is installed.

  MVP plugin security starts with an allowed-path policy and a required
  capability manifest. Later checks such as trust tiers, checksums, and
  journaled switch/rollback can build on this boundary without allowing
  partially loaded plugins.
  """

  alias Ourocode.Json
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
  def load_config_file(path) when is_binary(path) do
    with {:ok, config} <- ConfigSchema.parse_file(path) do
      {:ok, config_status_report(config)}
    end
  end

  @doc """
  Returns normalized plugin status records for a parsed plugin configuration.
  """
  @spec config_status_report(ConfigSchema.t()) :: config_load_report()
  def config_status_report(%ConfigSchema{plugins: plugins}) do
    records = Enum.map(plugins, &config_status_record/1)

    %{
      status: :ready,
      plugins: records,
      enabled_official_plugins:
        Enum.filter(records, &(&1.enabled? and &1.source_type == "official")),
      enabled_third_party_plugins:
        Enum.filter(records, &(&1.enabled? and &1.source_type == "third_party"))
    }
  end

  @doc """
  Normalizes a parsed plugin entry into the status shape used by UI/runtime panes.
  """
  @spec config_status_record(ConfigSchema.PluginEntry.t()) :: config_status_record()
  def config_status_record(%ConfigSchema.PluginEntry{} = plugin) do
    %{
      plugin_id: plugin.id,
      source_type: plugin.source,
      version: plugin.package_identity.version,
      enabled?: plugin.enabled,
      load_state: if(plugin.enabled, do: :load_requested, else: :disabled),
      path: plugin.path
    }
  end

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
    with {:ok, files} <- regular_plugin_files(plugin_path) do
      result =
        files
        |> Enum.sort_by(& &1.relative_path)
        |> Enum.reduce_while({:ok, :crypto.hash_init(:sha256)}, fn file, {:ok, context} ->
          case File.read(file.absolute_path) do
            {:ok, contents} ->
              next_context =
                context
                |> :crypto.hash_update(file.relative_path)
                |> :crypto.hash_update(<<0>>)
                |> :crypto.hash_update(contents)
                |> :crypto.hash_update(<<0>>)

              {:cont, {:ok, next_context}}

            {:error, _reason} ->
              {:halt, {:error, :plugin_checksum_unavailable}}
          end
        end)

      case result do
        {:ok, context} ->
          {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp verify_checksum(plugin_path, opts) do
    expected_checksum = Keyword.get(opts, :expected_checksum)

    if is_nil(expected_checksum) do
      {:error, :missing_plugin_checksum}
    else
      with {:ok, computed_checksum} <- checksum(plugin_path) do
        if computed_checksum == expected_checksum do
          {:ok, computed_checksum}
        else
          {:error, :plugin_checksum_mismatch}
        end
      end
    end
  end

  defp regular_plugin_files(plugin_path) do
    case File.ls(plugin_path) do
      {:ok, entries} ->
        with {:ok, absolute_paths} <- collect_regular_plugin_files(plugin_path, entries) do
          files =
            Enum.map(absolute_paths, fn absolute_path ->
              %{
                absolute_path: absolute_path,
                relative_path: Path.relative_to(absolute_path, plugin_path)
              }
            end)

          {:ok, files}
        end

      {:error, _reason} ->
        {:error, :plugin_checksum_unavailable}
    end
  end

  defp collect_regular_plugin_files(parent_path, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, files} ->
      path = Path.join(parent_path, entry)

      cond do
        File.regular?(path) ->
          {:cont, {:ok, [path | files]}}

        File.dir?(path) ->
          case File.ls(path) do
            {:ok, child_entries} ->
              case collect_regular_plugin_files(path, child_entries) do
                {:ok, child_files} -> {:cont, {:ok, child_files ++ files}}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            {:error, _reason} ->
              {:halt, {:error, :plugin_checksum_unavailable}}
          end

        true ->
          {:cont, {:ok, files}}
      end
    end)
  end
end
