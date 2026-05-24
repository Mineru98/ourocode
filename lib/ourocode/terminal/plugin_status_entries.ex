defmodule Ourocode.Terminal.PluginStatusEntries do
  @moduledoc """
  Projects plugin status reports into terminal status rows.
  """

  alias Ourocode.Terminal.{PluginStatusFields, PluginStatusTransitions}

  @spec from_configured_plugins(map(), [map()]) :: [map()]
  def from_configured_plugins(report, configured_plugins)
      when is_map(report) and is_list(configured_plugins) do
    PluginStatusTransitions.apply(report, configured_plugins)
  end

  @spec render_item(term()) :: map()
  def render_item(plugin) when is_map(plugin) do
    source_type = source_type(plugin)

    %{
      plugin_id: text_value(plugin, :plugin_id) || text_value(plugin, :id) || "plugin",
      source_type: source_type,
      source_label: source_label(source_type),
      source_badge: source_badge(source_type),
      version: text_value(plugin, :version) || "unknown",
      enabled?: boolean_value(plugin, :enabled?, false),
      load_state: field(plugin, :load_state, field(plugin, :state, :unknown)),
      status_entry: field(plugin, :status_entry, :current),
      transition_action: field(plugin, :transition_action),
      transition_reason: field(plugin, :transition_reason),
      path: text_value(plugin, :path) || "unknown"
    }
  end

  def render_item(_plugin) do
    %{
      plugin_id: "plugin",
      source_type: "unknown",
      source_label: "Unknown plugin",
      source_badge: "[UNKNOWN]",
      version: "unknown",
      enabled?: false,
      load_state: :unknown,
      status_entry: :current,
      transition_action: nil,
      transition_reason: nil,
      path: "unknown"
    }
  end

  defp source_label("official"), do: "Official plugin"
  defp source_label("third_party"), do: "Third-party plugin"
  defp source_label(_source_type), do: "Unknown plugin"

  defp source_badge("official"), do: "[OFFICIAL]"
  defp source_badge("third_party"), do: "[THIRD-PARTY]"
  defp source_badge(_source_type), do: "[UNKNOWN]"

  defp source_type(plugin) do
    [
      text_value(plugin, :source_type),
      text_value(plugin, :source),
      text_value(plugin, :plugin_source),
      plugin |> field(:source_metadata, %{}) |> text_value(:source),
      plugin |> field(:metadata, %{}) |> text_value(:plugin_source),
      plugin |> field(:source_attribution, %{}) |> text_value(:plugin_source)
    ]
    |> Enum.find(&(&1 in ["official", "third_party"]))
    |> Kernel.||("unknown")
  end

  defp field(map, key, default \\ nil), do: PluginStatusFields.value(map, key, default)
  defp text_value(map, key), do: PluginStatusFields.text(map, key)
  defp boolean_value(map, key, default), do: PluginStatusFields.boolean(map, key, default)
end
