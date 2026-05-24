defmodule Ourocode.Dashboard.ChildSessionPaneProjection do
  @moduledoc """
  Projects child session pane state into terminal-renderable maps.
  """

  alias Ourocode.Dashboard.ChildSessionPaneRenderer
  alias Ourocode.Dashboard.ChildSessionPaneStore

  @spec focused_state(map()) ::
          {:ok, map()}
          | {:error, :no_focused_child_session_pane | :focused_child_session_pane_not_found}
  def focused_state(%{working: working, completed: completed, focused: focused})
      when is_list(working) and is_list(completed) and is_binary(focused) and focused != "" do
    case Enum.find(working ++ completed, &(&1.id == focused)) do
      %{id: pane_id, kind: :child_session} = pane ->
        {:ok, pane |> Map.put(:pane_state, ChildSessionPaneStore.focused_pane_map(pane, pane_id))}

      _pane ->
        {:error, :focused_child_session_pane_not_found}
    end
  end

  def focused_state(%{focused: nil}), do: {:error, :no_focused_child_session_pane}
  def focused_state(%{focused: ""}), do: {:error, :no_focused_child_session_pane}
  def focused_state(_state), do: {:error, :focused_child_session_pane_not_found}

  @spec render_collection(map(), map()) :: map()
  def render_collection(
        %{working: working, completed: completed, focused: focused, open: open},
        registry
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(registry) do
    working = ChildSessionPaneStore.distinct(working)

    completed =
      completed
      |> ChildSessionPaneStore.reject_registered(working)
      |> ChildSessionPaneStore.distinct()

    %{
      id: :child_session_panes,
      title: "Child Sessions",
      empty?: working == [] and completed == [],
      focused: focused,
      open: open,
      child_pane_registry: registry,
      working: Enum.map(working, &ChildSessionPaneRenderer.render/1),
      completed: Enum.map(completed, &ChildSessionPaneRenderer.render/1)
    }
  end
end
