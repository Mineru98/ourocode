defmodule Ourocode.Runtime.ApplicationAccess do
  @moduledoc """
  Runtime accessors for supervised pane focus and registry state.
  """

  alias Ourocode.Runtime.FocusState

  @spec focus_pane(map(), FocusState.pane_id(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def focus_pane(%{services: %{pane_model: pane_pid, focus_state: focus_pid}}, pane_id, options)
      when is_pid(pane_pid) and is_pid(focus_pid) do
    pane_model = Agent.get(pane_pid, & &1)

    Agent.get_and_update(focus_pid, fn focus_state ->
      case FocusState.focus_pane(focus_state, pane_id, pane_model, options) do
        {:ok, updated_focus_state, event} ->
          {{:ok, %{focus_state: updated_focus_state, event: event}}, updated_focus_state}

        {:error, reason, unchanged_focus_state} ->
          {{:error, reason}, unchanged_focus_state}
      end
    end)
  end

  def focus_pane(_runtime, pane_id, _options), do: {:error, {:unknown_pane, pane_id}}

  @spec current_focus_state(map()) :: {:ok, map()} | {:error, :focus_state_unavailable}
  def current_focus_state(%{services: %{focus_state: focus_pid}}) when is_pid(focus_pid) do
    {:ok, Agent.get(focus_pid, & &1)}
  end

  def current_focus_state(_runtime), do: {:error, :focus_state_unavailable}

  @spec current_focused_child_session(map()) ::
          {:ok, FocusState.focused_child_session()}
          | {:error,
             :no_focused_child_session
             | :focused_child_session_pane_not_found
             | :focus_state_unavailable}
  def current_focused_child_session(%{services: %{pane_model: pane_pid, focus_state: focus_pid}})
      when is_pid(pane_pid) and is_pid(focus_pid) do
    pane_model = Agent.get(pane_pid, & &1)
    focus_state = Agent.get(focus_pid, & &1)

    FocusState.focused_child_session(focus_state, pane_model)
  end

  def current_focused_child_session(_runtime), do: {:error, :focus_state_unavailable}

  @spec current_command_registry(map()) :: {:ok, map()} | {:error, :command_registry_unavailable}
  def current_command_registry(%{services: %{command_registry: command_registry_pid}})
      when is_pid(command_registry_pid) do
    {:ok, Agent.get(command_registry_pid, & &1)}
  end

  def current_command_registry(_runtime), do: {:error, :command_registry_unavailable}

  @spec current_plugin_registry(map()) :: {:ok, map()} | {:error, :plugin_registry_unavailable}
  def current_plugin_registry(%{services: %{plugin_registry: plugin_registry_pid}})
      when is_pid(plugin_registry_pid) do
    {:ok, Agent.get(plugin_registry_pid, & &1)}
  end

  def current_plugin_registry(_runtime), do: {:error, :plugin_registry_unavailable}
end
