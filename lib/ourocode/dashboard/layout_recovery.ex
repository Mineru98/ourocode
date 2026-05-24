defmodule Ourocode.Dashboard.LayoutRecovery do
  @moduledoc """
  Replays persisted dashboard layout lifecycle records.

  The layout module owns geometry creation and hierarchy rendering. This module
  owns journal event recognition, layout metadata normalization, and view-state
  restoration after restart.
  """

  @layout_lifecycle_types MapSet.new([
                            :dashboard_layout_applied,
                            :dashboard_layout_updated,
                            :layout_applied,
                            :layout_updated
                          ])

  @doc """
  Replays layout journal events into dashboard layout state.
  """
  @spec recover_from_journal([map()], map()) :: map()
  def recover_from_journal(events, initial_state)
      when is_list(events) and is_map(initial_state) do
    Enum.reduce(events, initial_state, &apply_event(&2, &1))
  end

  @doc """
  Applies one persisted layout journal record to dashboard layout state.
  """
  @spec apply_event(map(), map()) :: map()
  def apply_event(state, event) when is_map(state) and is_map(event) do
    case layout_lifecycle_type(event) do
      {:ok, _type} ->
        state
        |> put_root_layout(event)
        |> put_pane_layouts(event)
        |> put_view_metadata(event)

      :ignore ->
        state
    end
  end

  @doc """
  Normalizes layout maps loaded from JSON or journal structs.
  """
  @spec normalize_layout_map(map()) :: map()
  def normalize_layout_map(layout) when is_map(layout) do
    Map.new(layout, fn {key, value} ->
      normalized_key = layout_key(key)
      {normalized_key, normalize_layout_value(normalized_key, value)}
    end)
  end

  defp layout_lifecycle_type(event) do
    case metadata_value(event, :type) do
      type when is_atom(type) ->
        if MapSet.member?(@layout_lifecycle_types, type), do: {:ok, type}, else: :ignore

      type when is_binary(type) ->
        type = string_to_existing_layout_type(type)

        if is_atom(type) and MapSet.member?(@layout_lifecycle_types, type) do
          {:ok, type}
        else
          :ignore
        end

      _type ->
        :ignore
    end
  end

  defp string_to_existing_layout_type("dashboard_layout_applied"), do: :dashboard_layout_applied
  defp string_to_existing_layout_type("dashboard_layout_updated"), do: :dashboard_layout_updated
  defp string_to_existing_layout_type("layout_applied"), do: :layout_applied
  defp string_to_existing_layout_type("layout_updated"), do: :layout_updated
  defp string_to_existing_layout_type(type), do: type

  defp put_root_layout(state, event) do
    case metadata_map(event, :layout, nil) do
      layout when is_map(layout) -> Map.put(state, :layout, normalize_layout_map(layout))
      _layout -> state
    end
  end

  defp put_pane_layouts(state, event) do
    event
    |> metadata_map(:pane_layouts, %{})
    |> Enum.reduce(state, fn {pane_key, layout}, acc ->
      pane_key = pane_layout_key(pane_key)

      if is_atom(pane_key) and is_map(layout) do
        Map.update(acc, pane_key, %{layout: normalize_layout_map(layout)}, fn
          pane when is_map(pane) -> Map.put(pane, :layout, normalize_layout_map(layout))
          pane -> pane
        end)
      else
        acc
      end
    end)
  end

  defp put_view_metadata(state, event) do
    state
    |> maybe_put_view_value(:focused, metadata_value(event, :focused))
    |> maybe_put_view_value(:open, metadata_value(event, :open))
  end

  defp maybe_put_view_value(state, _key, nil), do: state

  defp maybe_put_view_value(state, :focused, focused) when is_binary(focused) do
    Map.put(state, :focused, layout_atom(focused))
  end

  defp maybe_put_view_value(state, :focused, focused) when is_atom(focused) do
    Map.put(state, :focused, focused)
  end

  defp maybe_put_view_value(state, :open, open) when is_list(open) do
    Map.put(state, :open, Enum.map(open, &layout_atom/1))
  end

  defp maybe_put_view_value(state, _key, _value), do: state

  defp pane_layout_key(key) when key in [:working, :completed, :task_prompt], do: key
  defp pane_layout_key("working"), do: :working
  defp pane_layout_key("completed"), do: :completed
  defp pane_layout_key("task_prompt"), do: :task_prompt
  defp pane_layout_key("working_sessions"), do: :working
  defp pane_layout_key("completed_sessions"), do: :completed
  defp pane_layout_key(key), do: key

  defp normalize_layout_value(key, value) when key in [:mode, :region], do: layout_atom(value)

  defp normalize_layout_value(:panes, value) when is_list(value),
    do: Enum.map(value, &layout_atom/1)

  defp normalize_layout_value(:rect, value) when is_map(value), do: normalize_rect(value)
  defp normalize_layout_value(:regions, value) when is_map(value), do: normalize_regions(value)
  defp normalize_layout_value(_key, value), do: value

  defp normalize_regions(regions) do
    Map.new(regions, fn {key, value} ->
      {layout_atom(key), normalize_layout_map(value)}
    end)
  end

  defp normalize_rect(rect) do
    Map.new(rect, fn {key, value} -> {layout_key(key), value} end)
  end

  defp layout_key("mode"), do: :mode
  defp layout_key("region"), do: :region
  defp layout_key("order"), do: :order
  defp layout_key("rect"), do: :rect
  defp layout_key("x"), do: :x
  defp layout_key("y"), do: :y
  defp layout_key("width"), do: :width
  defp layout_key("height"), do: :height
  defp layout_key("regions"), do: :regions
  defp layout_key("panes"), do: :panes
  defp layout_key(key), do: key

  defp layout_atom(value) when is_atom(value), do: value
  defp layout_atom("compact"), do: :compact
  defp layout_atom("session_lists"), do: :session_lists
  defp layout_atom("task_prompt"), do: :task_prompt
  defp layout_atom("working_sessions"), do: :working_sessions
  defp layout_atom("completed_sessions"), do: :completed_sessions
  defp layout_atom(value), do: value

  defp metadata_map(metadata, key, default) do
    case metadata_value(metadata, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, to_string(key))
  end
end
