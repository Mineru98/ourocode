defmodule Ourocode.Dashboard.ChildSessionPaneFocus do
  @moduledoc """
  Focuses existing child session panes by pane or child identifier.
  """

  alias Ourocode.Dashboard.ChildSessionIdentity
  alias Ourocode.Dashboard.ChildSessionPaneLookup
  alias Ourocode.Dashboard.ChildSessionPaneState
  alias Ourocode.Dashboard.ChildSessionPaneStore

  @spec focus(map(), String.t()) ::
          {:ok, map()}
          | {:error, :child_session_pane_not_found | :invalid_child_session_focus}
  def focus(%{working: working, completed: completed, open: open} = state, selected_id)
      when is_list(working) and is_list(completed) and is_list(open) and is_binary(selected_id) do
    selected_id = ChildSessionIdentity.registry_child_id(selected_id)

    with true <- selected_id != "",
         {:ok, pane_id} <- existing_pane_id(state, selected_id) do
      {:ok,
       state
       |> Map.put(:working, ChildSessionPaneStore.mark_focused(working, pane_id))
       |> Map.put(:completed, ChildSessionPaneStore.mark_focused(completed, pane_id))
       |> Map.put(:focused, pane_id)
       |> Map.put(:open, ChildSessionPaneStore.append_once(open, pane_id))}
    else
      false -> {:error, :invalid_child_session_focus}
      :error -> {:error, :child_session_pane_not_found}
    end
  end

  def focus(_state, _selected_id), do: {:error, :invalid_child_session_focus}

  defp existing_pane_id(%{working: working, completed: completed} = state, selected_id) do
    case find_existing_pane(%{state | working: working, completed: completed}, selected_id) do
      %{id: pane_id} when is_binary(pane_id) -> {:ok, pane_id}
      _pane -> :error
    end
  end

  defp find_existing_pane(%{working: working, completed: completed} = state, selected_id)
       when is_list(working) and is_list(completed) and is_binary(selected_id) do
    ChildSessionPaneLookup.find_existing(
      working ++ completed,
      ChildSessionPaneState.registry(state),
      selected_id
    )
  end

  defp find_existing_pane(_state, _selected_id), do: nil
end
