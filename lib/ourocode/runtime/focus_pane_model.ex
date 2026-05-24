defmodule Ourocode.Runtime.FocusPaneModel do
  @moduledoc """
  Resolves terminal pane model ids and steering metadata for focus changes.
  """

  @type pane_id :: atom() | String.t()

  @spec resolve_pane_id(pane_id(), map()) :: {:ok, pane_id()} | :error
  def resolve_pane_id(target_pane_id, pane_model) when is_map(pane_model) do
    pane_ids = pane_ids(pane_model)

    cond do
      MapSet.member?(pane_ids, target_pane_id) ->
        {:ok, target_pane_id}

      is_binary(target_pane_id) ->
        target_atom = safe_existing_atom(target_pane_id)

        if not is_nil(target_atom) and MapSet.member?(pane_ids, target_atom) do
          {:ok, target_atom}
        else
          :error
        end

      is_atom(target_pane_id) ->
        target_string = Atom.to_string(target_pane_id)

        if MapSet.member?(pane_ids, target_string) do
          {:ok, target_string}
        else
          :error
        end

      true ->
        :error
    end
  end

  def resolve_pane_id(_target_pane_id, _pane_model), do: :error

  @spec valid_pane?(pane_id(), map()) :: boolean()
  def valid_pane?(target_pane_id, pane_model) do
    match?({:ok, _pane_id}, resolve_pane_id(target_pane_id, pane_model))
  end

  @spec steering_target(pane_id()) :: atom()
  def steering_target(:task_prompt), do: :parent
  def steering_target(:parent), do: :parent
  def steering_target("parent"), do: :parent
  def steering_target(:children), do: :child
  def steering_target("children"), do: :child
  def steering_target(:queue), do: :queue
  def steering_target("queue"), do: :queue
  def steering_target(:status), do: :status
  def steering_target("status"), do: :status
  def steering_target(:wonder_tool), do: :wonder_tool
  def steering_target("wonder_tool"), do: :wonder_tool

  def steering_target(pane_id) when is_binary(pane_id) do
    cond do
      String.starts_with?(pane_id, "child-") -> :child
      String.starts_with?(pane_id, "child:") -> :child
      String.starts_with?(pane_id, "child-session:") -> :child
      String.starts_with?(pane_id, "child-pane:") -> :child
      String.starts_with?(pane_id, "parent-") -> :parent
      String.starts_with?(pane_id, "parent:") -> :parent
      String.starts_with?(pane_id, "parent-mcp:") -> :parent
      true -> :pane
    end
  end

  def steering_target(_pane_id), do: :pane

  @spec steering_target_metadata(pane_id(), map(), atom()) :: map()
  def steering_target_metadata(pane_id, pane_model, steering_target) do
    pane = pane_entry(pane_id, pane_model) || %{}

    %{
      pane_id: pane_id,
      session_id: child_session_id(pane, pane_id, steering_target),
      kind: map_value(pane, :kind) || steering_target
    }
  end

  @spec pane_entry(pane_id(), map()) :: map() | nil
  def pane_entry(pane_id, pane_model) do
    panes = map_value(pane_model, :panes) || %{}

    Enum.find_value(panes, fn
      {^pane_id, pane} when is_map(pane) ->
        pane

      {_key, %{id: ^pane_id} = pane} ->
        pane

      {_key, %{"id" => ^pane_id} = pane} ->
        pane

      {_key, _pane} ->
        nil
    end)
  end

  @spec child_session_id(map() | nil, pane_id(), atom()) :: String.t() | nil
  def child_session_id(pane, pane_id, :child) when is_map(pane) do
    map_value(pane, :child_id) ||
      map_value(pane, :session_id) ||
      pane
      |> map_value(:external_ids)
      |> first_child_external_id() ||
      child_session_id(nil, pane_id, :child)
  end

  def child_session_id(_pane, pane_id, :child) when is_binary(pane_id) do
    cond do
      String.starts_with?(pane_id, "child-session:") ->
        String.replace_prefix(pane_id, "child-session:", "")

      String.starts_with?(pane_id, "child-pane:") ->
        String.replace_prefix(pane_id, "child-pane:", "")

      true ->
        nil
    end
  end

  def child_session_id(_pane, _pane_id, _steering_target), do: nil

  defp pane_ids(pane_model) do
    open_pane_ids =
      pane_model
      |> Map.get(:open, [])
      |> List.wrap()
      |> Enum.flat_map(&resolve_open_pane_id(&1, pane_model))

    MapSet.new([:task_prompt | open_pane_ids])
  end

  defp resolve_open_pane_id(open_pane_id, pane_model) do
    case map_value(pane_model, :panes) || %{} do
      %{^open_pane_id => %{id: pane_id}} -> [pane_id]
      %{^open_pane_id => %{"id" => pane_id}} -> [pane_id]
      _panes -> [open_pane_id]
    end
  end

  defp first_child_external_id(external_ids) when is_map(external_ids) do
    Enum.find_value(
      [
        {"childID", :childID},
        {"child_id", :child_id},
        {"session_id", :session_id},
        {"thread_id", :thread_id},
        {"native_session_id", :native_session_id}
      ],
      fn {string_key, atom_key} ->
        case Map.get(external_ids, string_key) || Map.get(external_ids, atom_key) do
          value when is_binary(value) and value != "" -> value
          _value -> nil
        end
      end
    )
  end

  defp first_child_external_id(_external_ids), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp safe_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end
