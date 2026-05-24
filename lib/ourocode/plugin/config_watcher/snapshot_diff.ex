defmodule Ourocode.Plugin.ConfigWatcher.SnapshotDiff do
  @moduledoc """
  Pure snapshot comparison rules for plugin config watcher sources.
  """

  @type change :: :created | :modified | :deleted
  @type relevance :: :relevant_config_change | :relevant_plugin_settings_change
  @type source_snapshot :: Ourocode.Plugin.ConfigWatcher.source_snapshot()

  @spec diff([source_snapshot()], [source_snapshot()]) :: [{change(), source_snapshot()}]
  def diff(before_snapshots, after_snapshots)
      when is_list(before_snapshots) and is_list(after_snapshots) do
    before_by_path = Map.new(before_snapshots, &{&1.path, &1})

    after_snapshots
    |> Enum.reduce([], fn after_snapshot, acc ->
      before_snapshot = Map.get(before_by_path, after_snapshot.path)

      case classify_change(before_snapshot, after_snapshot) do
        nil -> acc
        change -> [{change, after_snapshot} | acc]
      end
    end)
    |> Enum.reverse()
  end

  @spec relevance(change(), source_snapshot()) :: relevance()
  def relevance(change, %{kind: :plugin_settings, path: path})
      when change in [:created, :modified, :deleted] and is_binary(path) do
    :relevant_plugin_settings_change
  end

  def relevance(change, %{path: path})
      when change in [:created, :modified, :deleted] and is_binary(path) do
    :relevant_config_change
  end

  defp classify_change(nil, %{exists?: true}), do: :created
  defp classify_change(nil, %{exists?: false}), do: nil
  defp classify_change(%{exists?: false}, %{exists?: true}), do: :created
  defp classify_change(%{exists?: true}, %{exists?: false}), do: :deleted

  defp classify_change(%{exists?: true} = before_snapshot, %{exists?: true} = after_snapshot) do
    if Map.take(before_snapshot, [:size, :mtime, :checksum]) ==
         Map.take(after_snapshot, [:size, :mtime, :checksum]) do
      nil
    else
      :modified
    end
  end

  defp classify_change(_before_snapshot, _after_snapshot), do: nil
end
