defmodule Ourocode.Dashboard.ChildSessionPaneAccess do
  @moduledoc """
  Read and update accessors for first-class child session pane records.
  """

  alias Ourocode.Dashboard.ChildSessionPaneStore

  @spec fetch(map(), String.t()) :: {:ok, map()} | {:error, :child_session_pane_not_found}
  def fetch(%{working: working, completed: completed}, pane_id)
      when is_list(working) and is_list(completed) and is_binary(pane_id) do
    case Enum.find(working ++ completed, &(&1.id == pane_id)) do
      %{kind: :child_session} = pane -> {:ok, pane}
      _pane -> {:error, :child_session_pane_not_found}
    end
  end

  def fetch(_state, _pane_id), do: {:error, :child_session_pane_not_found}

  @spec update(map(), String.t(), map()) ::
          {:ok, map()} | {:error, :child_session_pane_not_found | :invalid_child_pane_update}
  def update(%{working: working, completed: completed} = state, pane_id, updates)
      when is_list(working) and is_list(completed) and is_binary(pane_id) and is_map(updates) do
    case Enum.find(working ++ completed, &(&1.id == pane_id)) do
      %{kind: :child_session} = pane ->
        updated_pane = ChildSessionPaneStore.apply_updates(pane, updates)

        {:ok,
         %{
           state
           | working: ChildSessionPaneStore.replace(working, pane_id, updated_pane),
             completed: ChildSessionPaneStore.replace(completed, pane_id, updated_pane)
         }}

      _pane ->
        {:error, :child_session_pane_not_found}
    end
  end

  def update(_state, _pane_id, _updates), do: {:error, :invalid_child_pane_update}
end
