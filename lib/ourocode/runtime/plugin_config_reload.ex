defmodule Ourocode.Runtime.PluginConfigReload do
  @moduledoc false

  alias Ourocode.Command.Registry, as: CommandRegistry
  alias Ourocode.Config
  alias Ourocode.Journal
  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Runtime.PluginConfigReloadState

  @spec handle(map(), map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def handle(
        %{
          services: %{
            plugin_registry: plugin_registry_pid,
            command_registry: command_registry_pid
          },
          journal: %{path: journal_path}
        },
        reload_request,
        options
      )
      when is_pid(plugin_registry_pid) and is_pid(command_registry_pid) and is_map(reload_request) do
    options = Map.new(options)
    before_plugins = Agent.get(plugin_registry_pid, & &1)
    before_commands = Agent.get(command_registry_pid, & &1)

    {reload_status, plugin_config, next_plugins} =
      reload_request
      |> read_reloaded_config(options)
      |> PluginConfigReloadState.reload_state(before_plugins, reload_request, options)

    next_commands = command_registry(reload_status, plugin_config, before_commands)
    reload_event = PluginConfigReloadState.reloaded_event(reload_request, next_plugins, options)

    with :ok <- Journal.append(journal_path, reload_event) do
      Agent.update(plugin_registry_pid, fn _plugins -> next_plugins end)
      Agent.update(command_registry_pid, fn _commands -> next_commands end)

      {:ok,
       %{
         status: reload_status,
         plugins: next_plugins,
         commands: next_commands,
         event: reload_event,
         journal_path: journal_path
       }}
    end
  end

  def handle(_runtime, _reload_request, _options), do: {:error, :plugin_registry_unavailable}

  @spec config_state(ConfigSchema.t() | nil | term()) :: map()
  def config_state(plugin_config), do: PluginConfigReloadState.config_state(plugin_config)

  defp read_reloaded_config(reload_request, options) do
    source_path =
      reload_request
      |> value(:config_source_path)
      |> case do
        path when is_binary(path) -> path
        _missing -> Map.get(options, :config_source_path)
      end

    cond do
      not is_binary(source_path) ->
        {:invalid, nil, :missing_config_source_path}

      reload_request |> value(:change) == :deleted ->
        {:missing, source_path, :deleted}

      not File.regular?(source_path) ->
        {:missing, source_path, :not_found}

      true ->
        source_path
        |> parse_config_source(options)
        |> case do
          {:ok, plugin_config} -> {:ok, source_path, plugin_config}
          {:error, reason} -> {:invalid, source_path, reason}
        end
    end
  end

  defp parse_config_source(source_path, options) do
    project_dir =
      options
      |> Map.get(:project_dir, Path.dirname(source_path))
      |> Path.expand()

    with {:ok, %{data: data}} <- Config.parse_config_file(source_path, project_dir),
         {:ok, plugins} <- fetch_plugin_config_list(data) do
      %{"plugins" => plugins}
      |> Ourocode.Json.encode!()
      |> IO.iodata_to_binary()
      |> ConfigSchema.parse()
    end
  end

  defp fetch_plugin_config_list(%{"plugins" => plugins}) when is_list(plugins), do: {:ok, plugins}

  defp fetch_plugin_config_list(%{"plugins" => _plugins}) do
    {:error, {:invalid_plugin_config_schema, "plugins must be a list"}}
  end

  defp fetch_plugin_config_list(_data) do
    {:error, {:invalid_plugin_config_schema, "plugins list is required"}}
  end

  defp command_registry(:loaded, plugin_config, _before_commands) do
    {:ok, command_registry} = CommandRegistry.load(skill_dirs: [], plugin_config: plugin_config)
    command_registry
  end

  defp command_registry(:missing, _plugin_config, _before_commands) do
    {:ok, command_registry} = CommandRegistry.load(skill_dirs: [], plugin_config: nil)
    command_registry
  end

  defp command_registry(:invalid, _plugin_config, before_commands), do: before_commands

  defp value(map, key, default \\ nil)

  defp value(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(_map, _key, default), do: default
end
