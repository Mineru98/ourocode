defmodule Ourocode.Terminal.WorkspaceNavigation do
  @moduledoc false

  @spec move(map() | nil, -1 | 1) :: map() | nil
  def move(nil, _direction), do: nil

  def move(workspace, direction) when is_map(workspace) and direction in [-1, 1] do
    records = records(workspace)

    case records do
      [] ->
        workspace

      _records ->
        index =
          workspace
          |> selected_index(records)
          |> Kernel.+(direction)
          |> clamp(length(records))

        select(workspace, Enum.at(records, index))
    end
  end

  @spec enter_action(map() | nil) :: String.t() | nil
  def enter_action(nil), do: nil

  def enter_action(workspace) when is_map(workspace) do
    detail = value(workspace, :detail, %{})

    detail
    |> value(:actions, [])
    |> List.wrap()
    |> Enum.find_value(&enabled_command/1)
  end

  @spec shortcut_action(map() | nil, String.t()) :: String.t() | nil
  def shortcut_action(nil, _shortcut), do: nil

  def shortcut_action(workspace, shortcut) when is_map(workspace) and is_binary(shortcut) do
    workspace
    |> value(:actions, [])
    |> List.wrap()
    |> Enum.find_value(fn action ->
      if shortcut_match?(action, shortcut), do: enabled_command(action)
    end)
  end

  @spec active?(term()) :: boolean()
  def active?(workspace), do: is_map(workspace) and records(workspace) != []

  defp select(workspace, nil), do: workspace

  defp select(workspace, record) do
    id = value(record, :id)

    workspace
    |> Map.put(:selected, id)
    |> Map.put("selected", id)
    |> Map.put(:detail, record)
    |> Map.put("detail", record)
  end

  defp selected_index(workspace, records) do
    selected = value(workspace, :selected)
    index = Enum.find_index(records, &(value(&1, :id) == selected))
    index || 0
  end

  defp clamp(index, count), do: min(max(index, 0), count - 1)

  defp records(workspace), do: value(workspace, :records, [])

  defp enabled_command(action) when is_map(action) do
    command = value(action, :command)

    if value(action, :enabled, true) and is_binary(command) and String.trim(command) != "" do
      command
    end
  end

  defp enabled_command(_action), do: nil

  defp shortcut_match?(action, shortcut) when is_map(action) do
    action
    |> value(:shortcut)
    |> case do
      nil -> false
      value -> String.downcase(to_string(value)) == String.downcase(shortcut)
    end
  end

  defp shortcut_match?(_action, _shortcut), do: false

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_map, _key, default), do: default
end
