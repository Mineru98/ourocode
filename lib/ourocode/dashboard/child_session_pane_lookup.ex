defmodule Ourocode.Dashboard.ChildSessionPaneLookup do
  @moduledoc """
  Locates existing child panes from pane ids, child ids, and external runtime ids.
  """

  alias Ourocode.Dashboard.ChildSessionMetadata

  @spec find_existing([map()], map(), String.t()) :: map() | nil
  def find_existing(panes, registry, selected_id)
      when is_list(panes) and is_map(registry) and is_binary(selected_id) do
    registered_pane_id = Map.get(registry, selected_id)
    Enum.find(panes, &pane_matches?(&1, selected_id, registered_pane_id))
  end

  def find_existing(_panes, _registry, _selected_id), do: nil

  @spec reusable_session_pane([map()], map()) :: map() | nil
  def reusable_session_pane(panes, external_ids) when is_list(panes) and is_map(external_ids) do
    external_ids
    |> strongest_session_identifiers()
    |> Enum.find_value(fn identifier ->
      Enum.find(panes, &external_id_matches?(Map.get(&1, :external_ids, %{}), identifier))
    end)
  end

  def reusable_session_pane(_panes, _external_ids), do: nil

  @spec external_id_matches?(term(), String.t()) :: boolean()
  def external_id_matches?(external_ids, selected_id) when is_map(external_ids) do
    Enum.any?(external_ids, fn {key, value} ->
      cond do
        ChildSessionMetadata.runtime_id_key?(key) and
            ChildSessionMetadata.normalize_runtime_id(value) == selected_id ->
          true

        is_map(value) ->
          external_id_matches?(value, selected_id)

        is_list(value) ->
          Enum.any?(value, &external_id_matches?(&1, selected_id))

        true ->
          false
      end
    end)
  end

  def external_id_matches?(_external_ids, _selected_id), do: false

  @spec strongest_session_identifiers(map()) :: [String.t()]
  def strongest_session_identifiers(external_ids) when is_map(external_ids) do
    [
      [
        :native_session_id,
        :nativeSessionID,
        :nativeSessionId,
        "native_session_id",
        "nativeSessionID",
        "nativeSessionId"
      ],
      [:thread_id, :threadID, :threadId, "thread_id", "threadID", "threadId"],
      [
        :input_session_id,
        :inputSessionID,
        :inputSessionId,
        "input_session_id",
        "inputSessionID",
        "inputSessionId"
      ],
      [
        :session_id,
        :sessionID,
        :sessionId,
        :_sessionId,
        "session_id",
        "sessionID",
        "sessionId",
        "_sessionId"
      ]
    ]
    |> Enum.find_value([], fn keys ->
      values = runtime_values_for_keys(external_ids, keys)
      if values == [], do: nil, else: values
    end)
  end

  def strongest_session_identifiers(_external_ids), do: []

  defp pane_matches?(%{id: id}, selected_id, _registered_pane_id) when id == selected_id,
    do: true

  defp pane_matches?(%{id: id}, _selected_id, registered_pane_id)
       when is_binary(registered_pane_id) and id == registered_pane_id,
       do: true

  defp pane_matches?(%{child_id: child_id}, selected_id, _registered_pane_id)
       when child_id == selected_id,
       do: true

  defp pane_matches?(%{external_ids: external_ids}, selected_id, _registered_pane_id)
       when is_map(external_ids) do
    external_id_matches?(external_ids, selected_id)
  end

  defp pane_matches?(_pane, _selected_id, _registered_pane_id), do: false

  defp runtime_values_for_keys(external_ids, keys) when is_map(external_ids) and is_list(keys) do
    direct_values =
      keys
      |> Enum.map(&Map.get(external_ids, &1))
      |> Enum.map(&ChildSessionMetadata.normalize_runtime_id/1)
      |> Enum.reject(&is_nil/1)

    nested_values =
      external_ids
      |> Map.values()
      |> Enum.flat_map(fn
        value when is_map(value) -> runtime_values_for_keys(value, keys)
        values when is_list(values) -> Enum.flat_map(values, &runtime_values_for_keys(&1, keys))
        _value -> []
      end)

    (direct_values ++ nested_values)
    |> Enum.uniq()
  end

  defp runtime_values_for_keys(_external_ids, _keys), do: []
end
