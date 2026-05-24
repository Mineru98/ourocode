defmodule Ourocode.Runtime.PluginSettingsReload do
  @moduledoc """
  Applies plugin-scoped settings reloads to live sessions and panes.
  """

  alias Ourocode.Journal
  alias Ourocode.Runtime.PluginSettingsState
  alias Ourocode.Runtime.Stream.Session

  @spec apply(map(), map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def apply(
        %{
          services: %{pane_model: pane_model_pid},
          journal: %{path: journal_path}
        },
        reload_request,
        options
      )
      when is_pid(pane_model_pid) and is_binary(journal_path) and is_map(reload_request) do
    options = Map.new(options)

    with {:ok, plugin_id} <- plugin_settings_plugin_id(reload_request, options),
         {:ok, session_pid} <- plugin_settings_session_pid(options),
         {:ok, pane_id, before_pane} <- plugin_settings_pane(pane_model_pid, options),
         {:ok, plugin_settings} <- read_plugin_settings(reload_request),
         session_settings <- session_settings_patch(plugin_settings),
         pane_settings <- pane_settings_patch(plugin_settings),
         event <-
           plugin_settings_applied_event(
             reload_request,
             plugin_id,
             pane_id,
             session_pid,
             plugin_settings,
             session_settings,
             pane_settings,
             options
           ),
         :ok <- Journal.append(journal_path, event),
         {:ok, session_snapshot} <- Session.apply_settings(session_pid, session_settings),
         {:ok, pane_model, updated_pane} <-
           update_plugin_settings_pane(
             pane_model_pid,
             pane_id,
             plugin_id,
             plugin_settings,
             pane_settings,
             event
           ) do
      {:ok,
       %{
         status: :applied,
         plugin_id: plugin_id,
         session_pid: session_pid,
         session_alive?: Process.alive?(session_pid),
         session_snapshot: session_snapshot,
         pane_id: pane_id,
         pane_preserved?: before_pane.id == updated_pane.id,
         pane_model: pane_model,
         pane: updated_pane,
         event: event,
         journal_path: journal_path
       }}
    end
  end

  def apply(_runtime, _reload_request, _options),
    do: {:error, :plugin_settings_reload_unavailable}

  @spec session_settings_patch(map()) :: map()
  def session_settings_patch(settings) do
    PluginSettingsState.session_patch(settings)
  end

  @spec pane_settings_patch(map()) :: map()
  def pane_settings_patch(settings) do
    PluginSettingsState.pane_patch(settings)
  end

  defp plugin_settings_plugin_id(reload_request, options) do
    case value(reload_request, :plugin_id) || Map.get(options, :plugin_id) do
      plugin_id when is_binary(plugin_id) and plugin_id != "" -> {:ok, plugin_id}
      _missing -> {:error, :missing_plugin_id}
    end
  end

  defp plugin_settings_session_pid(options) do
    case Map.get(options, :session_pid) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :session_process_not_alive}

      _missing ->
        {:error, :missing_session_pid}
    end
  end

  defp plugin_settings_pane(pane_model_pid, options) do
    pane_id = Map.get(options, :pane_id)
    pane_model = Agent.get(pane_model_pid, & &1)
    panes = Map.get(pane_model, :panes, %{})

    case {pane_id, Map.get(panes, pane_id)} do
      {pane_id, %{id: ^pane_id} = pane} when is_binary(pane_id) -> {:ok, pane_id, pane}
      {pane_id, _pane} when is_binary(pane_id) -> {:error, {:pane_not_found, pane_id}}
      _missing -> {:error, :missing_pane_id}
    end
  end

  defp read_plugin_settings(reload_request) do
    case value(reload_request, :change) do
      :deleted ->
        {:ok, %{}}

      "deleted" ->
        {:ok, %{}}

      _change ->
        reload_request
        |> value(:settings_source_path)
        |> case do
          path when is_binary(path) -> decode_plugin_settings(path)
          _missing -> {:error, :missing_settings_source_path}
        end
    end
  end

  defp decode_plugin_settings(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Ourocode.Json.decode(contents),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      false -> {:error, :invalid_plugin_settings_schema}
      {:error, reason} -> {:error, {:invalid_plugin_settings, reason}}
    end
  end

  defp plugin_settings_applied_event(
         reload_request,
         plugin_id,
         pane_id,
         session_pid,
         plugin_settings,
         session_settings,
         pane_settings,
         options
       ) do
    PluginSettingsState.applied_event(
      reload_request,
      plugin_id,
      pane_id,
      session_pid,
      plugin_settings,
      session_settings,
      pane_settings,
      options
    )
  end

  defp update_plugin_settings_pane(
         pane_model_pid,
         pane_id,
         plugin_id,
         plugin_settings,
         pane_settings,
         event
       ) do
    Agent.get_and_update(pane_model_pid, fn pane_model ->
      panes = Map.get(pane_model, :panes, %{})

      case Map.get(panes, pane_id) do
        %{id: ^pane_id} = pane ->
          updated_pane =
            put_plugin_settings_on_pane(pane, plugin_id, plugin_settings, pane_settings, event)

          updated_model = %{pane_model | panes: Map.put(panes, pane_id, updated_pane)}
          {{:ok, updated_model, updated_pane}, updated_model}

        _missing ->
          {{:error, {:pane_not_found, pane_id}}, pane_model}
      end
    end)
  end

  defp put_plugin_settings_on_pane(pane, plugin_id, plugin_settings, pane_settings, event) do
    PluginSettingsState.put_on_pane(pane, plugin_id, plugin_settings, pane_settings, event)
  end

  defp value(map, key, default \\ nil)

  defp value(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(_map, _key, default), do: default
end
