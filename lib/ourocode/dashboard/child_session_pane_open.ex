defmodule Ourocode.Dashboard.ChildSessionPaneOpen do
  @moduledoc """
  Resolves and opens child session panes from user/runtime identifiers.
  """

  alias Ourocode.Dashboard.ChildSessionMetadata
  alias Ourocode.Dashboard.ChildSessionOpenRequest
  alias Ourocode.Dashboard.ChildSessionPaneFocus
  alias Ourocode.Dashboard.ChildSessionPaneLookup
  alias Ourocode.Dashboard.ChildSessionPaneRegistration
  alias Ourocode.Dashboard.ChildSessionPaneState

  @spec resolve(map(), String.t(), map() | keyword()) ::
          {:ok, map()}
          | {:error, :invalid_child_session_identifier | :invalid_child_session_state}
  def resolve(state, identifier, options \\ %{})

  def resolve(%{working: working, completed: completed} = state, identifier, options)
      when is_list(working) and is_list(completed) and is_binary(identifier) do
    with {:ok, normalized_identifier} <- ChildSessionOpenRequest.normalize_identifier(identifier),
         {:ok, create_child_id} <- ChildSessionOpenRequest.child_id(normalized_identifier) do
      case find_existing_pane(state, normalized_identifier) do
        %{id: pane_id, child_id: child_id} = pane ->
          {:ok,
           %{
             kind: :existing_session,
             identifier: normalized_identifier,
             child_id: child_id,
             pane_id: pane_id,
             session: pane
           }}

        nil ->
          resolve_missing_pane(state, normalized_identifier, create_child_id, options)
      end
    end
  end

  def resolve(%{working: working, completed: completed}, _identifier, _options)
      when is_list(working) and is_list(completed),
      do: {:error, :invalid_child_session_identifier}

  def resolve(_state, _identifier, _options), do: {:error, :invalid_child_session_state}

  @spec open_resolved(map(), map()) ::
          {:ok, map()}
          | {:error,
             :invalid_child_session_resolution
             | :invalid_child_pane_metadata
             | :child_session_pane_not_found
             | :invalid_child_session_focus}
  def open_resolved(state, %{kind: :existing_session, pane_id: pane_id})
      when is_binary(pane_id) do
    ChildSessionPaneFocus.focus(state, pane_id)
  end

  def open_resolved(
        %{working: working, completed: completed, focused: focused, open: open} = state,
        %{kind: :create_open_request, request: request}
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(request) do
    should_focus? = no_active_child_pane?(focused, open)

    with {:ok, state} <-
           ChildSessionPaneRegistration.register(
             state,
             ChildSessionOpenRequest.metadata(request, should_focus?)
           ) do
      pane_id = ChildSessionMetadata.value(request, :pane_id)

      if should_focus? and is_binary(pane_id) do
        ChildSessionPaneFocus.focus(state, pane_id)
      else
        {:ok, state}
      end
    end
  end

  def open_resolved(_state, _resolution),
    do: {:error, :invalid_child_session_resolution}

  @spec open(map(), String.t(), map() | keyword()) ::
          {:ok, map()}
          | {:error,
             :invalid_child_session_resolution
             | :invalid_child_pane_metadata
             | :child_session_pane_not_found
             | :invalid_child_session_focus
             | :invalid_child_session_identifier
             | :invalid_child_session_state}
  def open(state, identifier, options \\ %{}) do
    with {:ok, resolution} <- resolve(state, identifier, options) do
      open_resolved(state, resolution)
    end
  end

  defp resolve_missing_pane(state, normalized_identifier, create_child_id, options) do
    case find_existing_pane_from_options(state, options) do
      %{id: pane_id, child_id: child_id} = pane ->
        {:ok,
         %{
           kind: :existing_session,
           identifier: normalized_identifier,
           child_id: child_id,
           pane_id: pane_id,
           session: pane
         }}

      nil ->
        pane_id = create_request_pane_id(state, create_child_id)

        {:ok,
         %{
           kind: :create_open_request,
           identifier: normalized_identifier,
           child_id: create_child_id,
           pane_id: pane_id,
           request:
             ChildSessionOpenRequest.build(
               create_child_id,
               normalized_identifier,
               pane_id,
               options
             )
         }}
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

  defp find_existing_pane_from_options(%{working: working, completed: completed}, options)
       when is_list(working) and is_list(completed) do
    external_ids =
      options
      |> Map.new()
      |> ChildSessionMetadata.map_value(:external_ids, %{})

    ChildSessionPaneLookup.reusable_session_pane(working ++ completed, external_ids)
  end

  defp find_existing_pane_from_options(_state, _options), do: nil

  defp create_request_pane_id(state, child_id) do
    state
    |> ChildSessionPaneState.registry()
    |> ChildSessionOpenRequest.pane_id(child_id)
  end

  defp no_active_child_pane?(focused, open) do
    focused in [nil, ""] and open == []
  end
end
