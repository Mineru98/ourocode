defmodule Ourocode.Plugin.ConfigWatcher.Sources do
  @moduledoc false

  alias Ourocode.Config

  @type source_kind :: :plugin_config | :plugin_settings
  @type source :: %{
          required(:kind) => source_kind(),
          required(:path) => Path.t(),
          optional(:plugin_id) => String.t()
        }
  @type snapshot :: %{
          required(:path) => Path.t(),
          required(:kind) => source_kind(),
          required(:exists?) => boolean(),
          optional(:plugin_id) => String.t(),
          optional(:size) => non_neg_integer(),
          optional(:mtime) => term(),
          optional(:checksum) => String.t()
        }

  @spec config_paths(Path.t(), keyword() | map()) :: [Path.t()]
  def config_paths(project_dir, options \\ []) when is_binary(project_dir) do
    options = options_map(options)

    case Map.get(options, :source_paths) do
      paths when is_list(paths) and paths != [] ->
        paths

      _paths ->
        Config.supported_config_candidates()
        |> Enum.map(&Path.join(project_dir, &1))
    end
    |> Enum.map(&Path.expand(&1, project_dir))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec watch_sources(Path.t(), [Path.t()], keyword() | map()) :: [source()]
  def watch_sources(project_dir, source_paths, options)
      when is_binary(project_dir) and is_list(source_paths) do
    config_sources =
      Enum.map(source_paths, fn path ->
        %{kind: :plugin_config, path: Path.expand(path, project_dir)}
      end)

    config_sources ++ plugin_setting_paths(project_dir, options_map(options))
  end

  @spec plugin_setting_paths(Path.t(), keyword() | map()) :: [source()]
  def plugin_setting_paths(project_dir, options) when is_binary(project_dir) do
    options = options_map(options)

    options
    |> Map.get(:plugin_setting_paths, Map.get(options, :plugin_settings_paths, []))
    |> List.wrap()
    |> Enum.flat_map(&normalize_plugin_setting_path(&1, project_dir))
    |> Enum.uniq_by(fn source -> {source.plugin_id, source.path} end)
    |> Enum.sort_by(fn source -> {source.plugin_id, source.path} end)
  end

  @spec snapshots([source()]) :: [snapshot()]
  def snapshots(sources) when is_list(sources) do
    Enum.map(sources, &snapshot/1)
  end

  @spec snapshot(source()) :: snapshot()
  def snapshot(%{path: path} = source) do
    expanded_path = Path.expand(path)
    metadata = source |> Map.take([:kind, :plugin_id]) |> Map.put(:path, expanded_path)

    case File.stat(expanded_path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        Map.merge(metadata, %{
          exists?: true,
          size: size,
          mtime: mtime,
          checksum: file_checksum(expanded_path)
        })

      {:ok, _stat} ->
        Map.put(metadata, :exists?, false)

      {:error, _reason} ->
        Map.put(metadata, :exists?, false)
    end
  end

  defp normalize_plugin_setting_path(%{plugin_id: plugin_id, path: path}, project_dir)
       when is_binary(plugin_id) and is_binary(path) do
    [%{kind: :plugin_settings, plugin_id: plugin_id, path: Path.expand(path, project_dir)}]
  end

  defp normalize_plugin_setting_path(%{"plugin_id" => plugin_id, "path" => path}, project_dir)
       when is_binary(plugin_id) and is_binary(path) do
    [%{kind: :plugin_settings, plugin_id: plugin_id, path: Path.expand(path, project_dir)}]
  end

  defp normalize_plugin_setting_path({plugin_id, paths}, project_dir)
       when is_binary(plugin_id) and is_list(paths) do
    Enum.flat_map(paths, &normalize_plugin_setting_path({plugin_id, &1}, project_dir))
  end

  defp normalize_plugin_setting_path({plugin_id, path}, project_dir)
       when is_binary(plugin_id) and is_binary(path) do
    [%{kind: :plugin_settings, plugin_id: plugin_id, path: Path.expand(path, project_dir)}]
  end

  defp normalize_plugin_setting_path(_source, _project_dir), do: []

  defp file_checksum(path) do
    case File.read(path) do
      {:ok, contents} -> :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
      {:error, _reason} -> nil
    end
  end

  defp options_map(options) when is_map(options), do: options
  defp options_map(options) when is_list(options), do: Map.new(options)
end
