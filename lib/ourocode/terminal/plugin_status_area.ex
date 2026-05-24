defmodule Ourocode.Terminal.PluginStatusArea do
  @moduledoc """
  Terminal-native plugin status projection.

  The plugin loader owns normalization. This module keeps the terminal surface
  render-only: it accepts the current normalized status report or plugin list
  and emits one visible row for every normalized plugin entry.
  """

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.Loader
  alias Ourocode.Terminal.{LayoutSegment, PluginStatusEntries, PluginStatusFields}

  @default_width 80
  @default_y 18
  @reserved_frame_lines 3

  @type rendered_area :: %{
          required(:id) => :plugin_status,
          required(:kind) => :terminal_plugin_status_area,
          required(:title) => String.t(),
          required(:status) => atom() | String.t(),
          required(:plugin_count) => non_neg_integer(),
          required(:visible_count) => non_neg_integer(),
          required(:items) => [map()],
          required(:layout) => map()
        }

  @doc """
  Builds a render-ready plugin status area from terminal startup/runtime state.
  """
  @spec render(map() | [map()]) :: rendered_area()
  def render(state) do
    report = status_report(state)
    items = report |> value(:plugins, []) |> Enum.map(&PluginStatusEntries.render_item/1)
    height = max(@reserved_frame_lines + length(items), @reserved_frame_lines + 1)

    %{
      id: :plugin_status,
      kind: :terminal_plugin_status_area,
      title: "Plugin Status",
      status: value(report, :status, :unknown),
      plugin_count: length(items),
      visible_count: length(items),
      items: items,
      layout: %{
        mode: :terminal_stack,
        region: :plugin_status,
        order: 40,
        rect: %{x: 0, y: @default_y, width: @default_width, height: height}
      }
    }
  end

  @doc """
  Renders plugin status as terminal-safe text.
  """
  @spec render_text(rendered_area() | map() | [map()]) :: String.t()
  def render_text(%{kind: :terminal_plugin_status_area} = area) do
    [
      "+-- #{area.title} (#{area.plugin_count}) #{LayoutSegment.format(area, "plugin_status")}",
      "| status=#{area.status} visible=#{area.visible_count}"
      | item_lines(area.items)
    ]
    |> Kernel.++(["+--"])
    |> Enum.join("\n")
  end

  def render_text(state) do
    state
    |> render()
    |> render_text()
  end

  defp status_report(%ConfigSchema{} = config), do: Loader.config_status_report(config)

  defp status_report(%{plugins: plugins} = report) when is_list(plugins), do: report
  defp status_report(%{"plugins" => plugins} = report) when is_list(plugins), do: report

  defp status_report(%{configured_plugins: plugins} = report) when is_list(plugins),
    do: Map.put(report, :plugins, PluginStatusEntries.from_configured_plugins(report, plugins))

  defp status_report(%{"configured_plugins" => plugins} = report) when is_list(plugins),
    do: Map.put(report, "plugins", PluginStatusEntries.from_configured_plugins(report, plugins))

  defp status_report(plugins) when is_list(plugins), do: %{status: :ready, plugins: plugins}

  defp status_report(state) when is_map(state) do
    find_report([
      value(state, :plugin_status),
      value(state, :plugins),
      state |> value(:runtime, %{}) |> value(:plugin_status),
      state |> value(:runtime, %{}) |> value(:plugins),
      state |> value(:context, %{}) |> value(:plugin_status),
      state |> value(:context, %{}) |> value(:plugins),
      state |> value(:context, %{}) |> value(:plugin_config),
      value(state, :plugin_config)
    ])
  end

  defp status_report(_state), do: %{status: :unknown, plugins: []}

  defp find_report([]), do: %{status: :unknown, plugins: []}
  defp find_report([nil | rest]), do: find_report(rest)
  defp find_report([%ConfigSchema{} = config | _rest]), do: Loader.config_status_report(config)
  defp find_report([%{plugins: plugins} = report | _rest]) when is_list(plugins), do: report
  defp find_report([%{"plugins" => plugins} = report | _rest]) when is_list(plugins), do: report

  defp find_report([%{configured_plugins: plugins} = report | _rest]) when is_list(plugins),
    do: Map.put(report, :plugins, PluginStatusEntries.from_configured_plugins(report, plugins))

  defp find_report([%{"configured_plugins" => plugins} = report | _rest]) when is_list(plugins),
    do: Map.put(report, "plugins", PluginStatusEntries.from_configured_plugins(report, plugins))

  defp find_report([plugins | _rest]) when is_list(plugins),
    do: %{status: :ready, plugins: plugins}

  defp find_report([_candidate | rest]), do: find_report(rest)

  defp item_lines([]), do: ["| empty"]

  defp item_lines(items) do
    Enum.map(items, fn item ->
      [
        "| plugin",
        item.source_badge,
        "id=#{item.plugin_id}",
        "label=#{item.source_label}",
        "source=#{item.source_type}",
        "version=#{item.version}",
        "enabled?=#{item.enabled?}",
        "state=#{item.load_state}",
        "path=#{item.path}"
      ]
      |> Enum.join(" ")
    end)
  end

  defp value(map, key, default \\ nil), do: PluginStatusFields.value(map, key, default)
end
