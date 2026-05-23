defmodule Ourocode.Terminal.PluginStatusArea do
  @moduledoc """
  Terminal-native plugin status projection.

  The plugin loader owns normalization. This module keeps the terminal surface
  render-only: it accepts the current normalized status report or plugin list
  and emits one visible row for every normalized plugin entry.
  """

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.Loader

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
    items = report |> value(:plugins, []) |> Enum.map(&render_item/1)
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
      "+-- #{area.title} (#{area.plugin_count}) #{layout_segment(area)}",
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
    do: Map.put(report, :plugins, plugin_status_entries(report, plugins))

  defp status_report(%{"configured_plugins" => plugins} = report) when is_list(plugins),
    do: Map.put(report, "plugins", plugin_status_entries(report, plugins))

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
    do: Map.put(report, :plugins, plugin_status_entries(report, plugins))

  defp find_report([%{"configured_plugins" => plugins} = report | _rest]) when is_list(plugins),
    do: Map.put(report, "plugins", plugin_status_entries(report, plugins))

  defp find_report([plugins | _rest]) when is_list(plugins),
    do: %{status: :ready, plugins: plugins}

  defp find_report([_candidate | rest]), do: find_report(rest)

  defp render_item(plugin) when is_map(plugin) do
    source_type = source_type(plugin)

    %{
      plugin_id: text_value(plugin, :plugin_id) || text_value(plugin, :id) || "plugin",
      source_type: source_type,
      source_label: source_label(source_type),
      source_badge: source_badge(source_type),
      version: text_value(plugin, :version) || "unknown",
      enabled?: boolean_value(plugin, :enabled?, false),
      load_state: value(plugin, :load_state, value(plugin, :state, :unknown)),
      status_entry: value(plugin, :status_entry, :current),
      transition_action: value(plugin, :transition_action),
      transition_reason: value(plugin, :transition_reason),
      path: text_value(plugin, :path) || "unknown"
    }
  end

  defp render_item(_plugin) do
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

  defp plugin_status_entries(report, configured_plugins) do
    transitions = transition_events(report)

    case transitions do
      [_ | _] -> hot_reload_status_entries(report, configured_plugins, transitions)
      _transitions -> configured_plugins
    end
  end

  defp transition_events(report) do
    case value(report, :plugin_transitions, []) do
      [_ | _] = transitions -> transitions
      _empty -> value(report, :load_transitions, [])
    end
  end

  defp hot_reload_status_entries(report, configured_plugins, transitions) do
    plugins_by_id =
      report
      |> value(:plugins_by_id, Map.new(configured_plugins, &{text_value(&1, :id), &1}))
      |> normalize_plugins_by_id()

    transitions_by_id =
      Map.new(transitions, fn transition ->
        {text_value(transition, :plugin_id) || "plugin", transition}
      end)

    configured_plugins
    |> Enum.map(fn plugin ->
      plugin_id = text_value(plugin, :id) || text_value(plugin, :plugin_id) || "plugin"
      plugin = Map.get(plugins_by_id, plugin_id, plugin)

      case Map.fetch(transitions_by_id, plugin_id) do
        {:ok, transition} -> transition_status_entry(plugin_id, plugin, transition)
        :error -> plugin
      end
    end)
    |> Kernel.++(transition_only_status_entries(plugins_by_id, transitions, configured_plugins))
  end

  defp transition_status_entry(plugin_id, plugin, transition) do
    load_error = value(transition, :load_error) || value(plugin, :load_error)

    plugin
    |> Map.merge(%{
      plugin_id: plugin_id,
      id: text_value(plugin, :id) || plugin_id,
      enabled?: transition_enabled?(transition, plugin),
      state: transition_load_state(transition),
      load_state: transition_load_state(transition),
      status_entry: transition_status_entry(transition),
      transition_action: value(transition, :action),
      transition_reason: value(transition, :reason)
    })
    |> maybe_put(:load_error, load_error)
  end

  defp transition_only_status_entries(plugins_by_id, transitions, configured_plugins) do
    configured_ids =
      MapSet.new(
        configured_plugins,
        &(text_value(&1, :id) || text_value(&1, :plugin_id) || "plugin")
      )

    transitions
    |> Enum.reject(fn transition ->
      MapSet.member?(configured_ids, text_value(transition, :plugin_id) || "plugin")
    end)
    |> Enum.map(fn transition ->
      plugin_id = text_value(transition, :plugin_id) || "plugin"
      transition_status_entry(plugin_id, Map.get(plugins_by_id, plugin_id, %{}), transition)
    end)
  end

  defp normalize_plugins_by_id(plugins_by_id) when is_map(plugins_by_id) do
    Map.new(plugins_by_id, fn {plugin_id, plugin} -> {to_string(plugin_id), plugin} end)
  end

  defp normalize_plugins_by_id(_plugins_by_id), do: %{}

  defp transition_enabled?(transition, plugin) do
    case transition_load_state(transition) do
      :disabled -> false
      :load_failed -> boolean_value(plugin, :enabled?, true)
      :newly_loaded -> true
      :enabled -> true
      _state -> boolean_value(plugin, :enabled?, false)
    end
  end

  defp transition_load_state(transition) do
    action = value(transition, :action)
    to = value(transition, :to)

    cond do
      action in [:load_failed, "load_failed"] or to in [:load_failed, "load_failed"] ->
        :load_failed

      action in [:load_requested, "load_requested"] ->
        :newly_loaded

      action in [
        :skip_load,
        "skip_load",
        :unload_requested,
        "unload_requested",
        :keep_disabled,
        "keep_disabled"
      ] or to in [:disabled, "disabled", :unconfigured, "unconfigured"] ->
        :disabled

      to in [:enabled, "enabled"] ->
        :enabled

      true ->
        :unknown
    end
  end

  defp transition_status_entry(transition) do
    case transition_load_state(transition) do
      :newly_loaded -> :newly_loaded_plugin
      :disabled -> :disabled_plugin
      :load_failed -> :failed_plugin
      state -> state
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp layout_segment(%{layout: %{rect: rect, region: region}}) do
    "region=#{region} x=#{rect.x} y=#{rect.y} w=#{rect.width} h=#{rect.height}"
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
      plugin |> value(:source_metadata, %{}) |> text_value(:source),
      plugin |> value(:metadata, %{}) |> text_value(:plugin_source),
      plugin |> value(:source_attribution, %{}) |> text_value(:plugin_source)
    ]
    |> Enum.find(&(&1 in ["official", "third_party"]))
    |> Kernel.||("unknown")
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default

  defp value(_map, _key, default), do: default

  defp text_value(map, key) do
    case value(map, key) do
      nil -> nil
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp boolean_value(map, key, default) do
    case value(map, key) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end
end
