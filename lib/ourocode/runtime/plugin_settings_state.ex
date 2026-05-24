defmodule Ourocode.Runtime.PluginSettingsState do
  @moduledoc """
  Pure plugin settings patches and pane state updates.
  """

  @spec session_patch(map()) :: map()
  def session_patch(settings) do
    settings
    |> setting_map(:session_settings)
    |> case do
      nil -> setting_map(settings, :session) || %{}
      session_settings -> session_settings
    end
  end

  @spec pane_patch(map()) :: map()
  def pane_patch(settings) do
    settings
    |> setting_map(:pane_settings)
    |> case do
      nil -> setting_map(settings, :pane) || %{}
      pane_settings -> pane_settings
    end
  end

  @spec applied_event(map(), String.t(), String.t(), pid(), map(), map(), map(), map()) :: map()
  def applied_event(
        reload_request,
        plugin_id,
        pane_id,
        session_pid,
        plugin_settings,
        session_settings,
        pane_settings,
        options
      ) do
    %{
      type: :plugin_settings_applied,
      event_type: :plugin_settings_applied,
      source: :plugin_registry,
      plugin_id: plugin_id,
      pane_id: pane_id,
      session_pid: inspect(session_pid),
      change: value(reload_request, :change),
      request_id: value(reload_request, :request_id),
      settings_source_path: value(reload_request, :settings_source_path),
      settings_source_relative_path: value(reload_request, :settings_source_relative_path),
      settings_source_signature: value(reload_request, :settings_source_signature),
      plugin_settings: plugin_settings,
      session_settings: session_settings,
      pane_settings: pane_settings,
      occurred_at_ms: Map.get(options, :occurred_at_ms, System.system_time(:millisecond)),
      reload_boundary: :elixir_runtime,
      ui_restart_required?: false
    }
  end

  @spec put_on_pane(map(), String.t(), map(), map(), map()) :: map()
  def put_on_pane(pane, plugin_id, plugin_settings, pane_settings, event) do
    pane_state =
      pane
      |> Map.get(:pane_state, %{})
      |> Map.put(:plugin_settings, plugin_settings)
      |> Map.update(:plugin_settings_by_plugin, %{plugin_id => plugin_settings}, fn by_plugin ->
        Map.put(by_plugin, plugin_id, plugin_settings)
      end)
      |> Map.put(:plugin_pane_settings, pane_settings)
      |> Map.put(:last_plugin_settings_reload, %{
        plugin_id: plugin_id,
        request_id: event.request_id,
        change: event.change,
        occurred_at_ms: event.occurred_at_ms
      })

    %{pane | pane_state: pane_state, updated_at_ms: event.occurred_at_ms}
  end

  defp setting_map(settings, key) when is_map(settings) do
    case value(settings, key) do
      map when is_map(map) -> map
      _missing_or_invalid -> nil
    end
  end

  defp setting_map(_settings, _key), do: nil

  defp value(map, key, default \\ nil)

  defp value(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(_map, _key, default), do: default
end
