defmodule Ourocode.Plugin.ConfigStatus do
  @moduledoc """
  Projects parsed plugin configuration into load-status records.
  """

  alias Ourocode.Plugin.ConfigSchema

  @type record :: %{
          required(:plugin_id) => String.t(),
          required(:source_type) => String.t(),
          required(:version) => String.t(),
          required(:enabled?) => boolean(),
          required(:load_state) => :load_requested | :disabled,
          required(:path) => String.t()
        }

  @type report :: %{
          required(:status) => :ready,
          required(:plugins) => [record()],
          required(:enabled_official_plugins) => [record()],
          required(:enabled_third_party_plugins) => [record()]
        }

  @spec load_file(Path.t()) :: {:ok, report()} | {:error, ConfigSchema.parse_error()}
  def load_file(path) when is_binary(path) do
    with {:ok, config} <- ConfigSchema.parse_file(path) do
      {:ok, report(config)}
    end
  end

  @spec report(ConfigSchema.t()) :: report()
  def report(%ConfigSchema{plugins: plugins}) do
    records = Enum.map(plugins, &record/1)

    %{
      status: :ready,
      plugins: records,
      enabled_official_plugins:
        Enum.filter(records, &(&1.enabled? and &1.source_type == "official")),
      enabled_third_party_plugins:
        Enum.filter(records, &(&1.enabled? and &1.source_type == "third_party"))
    }
  end

  @spec record(ConfigSchema.PluginEntry.t()) :: record()
  def record(%ConfigSchema.PluginEntry{} = plugin) do
    %{
      plugin_id: plugin.id,
      source_type: plugin.source,
      version: plugin.package_identity.version,
      enabled?: plugin.enabled,
      load_state: if(plugin.enabled, do: :load_requested, else: :disabled),
      path: plugin.path
    }
  end
end
