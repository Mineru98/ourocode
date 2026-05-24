defmodule Ourocode.Plugin.ConfigRoot do
  @moduledoc """
  Parses the root plugin configuration map.
  """

  alias Ourocode.Plugin.ConfigPluginEntry

  @type parse_error :: {:invalid_plugin_config_schema, String.t()}

  @spec parse(map()) ::
          {:ok, [Ourocode.Plugin.ConfigSchema.PluginEntry.t()]} | {:error, parse_error()}
  def parse(%{"plugins" => plugins}) when is_list(plugins) do
    plugins
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {plugin, index}, {:ok, acc} ->
      case ConfigPluginEntry.parse(plugin, index) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} ->
        entries
        |> Enum.reverse()
        |> ConfigPluginEntry.validate_unique_ids()

      {:error, reason} ->
        {:error, reason}
    end
  end

  def parse(%{"plugins" => _plugins}) do
    schema_error("plugins must be a list")
  end

  def parse(_decoded) do
    schema_error("plugins list is required")
  end

  defp schema_error(message) do
    {:error, {:invalid_plugin_config_schema, message}}
  end
end
