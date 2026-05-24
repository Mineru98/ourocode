defmodule Ourocode.Journal.RelationshipRecoveryFields do
  @moduledoc """
  Derived fields used by relationship recovery records.
  """

  alias Ourocode.Journal.RelationshipEventFields, as: Fields

  @spec external_ids(map(), String.t()) :: map()
  def external_ids(event, child_id) when is_map(event) and is_binary(child_id) do
    event
    |> Fields.map_value(:external_ids, %{})
    |> Map.put_new("childID", child_id)
  end

  @spec stream_cursor(map(), atom(), non_neg_integer(), String.t()) :: map()
  def stream_cursor(event, transport, event_seq, child_id)
      when is_map(event) and is_integer(event_seq) and is_binary(child_id) do
    event
    |> Fields.map_value(:stream_cursor, %{})
    |> Map.merge(%{
      transport: transport,
      child_id: child_id,
      event_seq: event_seq
    })
  end

  @spec acknowledged_stream_cursor(map(), atom(), non_neg_integer(), String.t()) :: map() | nil
  def acknowledged_stream_cursor(event, transport, event_seq, child_id)
      when is_map(event) and is_integer(event_seq) and is_binary(child_id) do
    event
    |> acknowledged_stream_cursor_value()
    |> case do
      cursor when is_map(cursor) ->
        Map.merge(cursor, %{
          transport: transport,
          child_id: child_id,
          event_seq: event_seq
        })

      _cursor ->
        nil
    end
  end

  @spec pane_state(map()) :: map()
  def pane_state(event) when is_map(event), do: Fields.map_value(event, :pane_state, %{})

  @spec pane_id(map(), String.t(), String.t() | nil) :: String.t()
  def pane_id(event, child_id, extracted_pane_key \\ nil)
      when is_map(event) and is_binary(child_id) do
    Fields.string_value(event, :pane_id) || Fields.string_value(event, :id) ||
      extracted_pane_key ||
      "child-session:" <> child_id
  end

  @spec status(map(), atom()) :: :working | :completed | nil
  def status(event, event_type) when is_map(event) and is_atom(event_type) do
    case Fields.value(event, :status) do
      status when status in [:working, :completed] -> status
      "working" -> :working
      "completed" -> :completed
      _status when event_type == :child_pane_completed -> :completed
      _status -> nil
    end
  end

  defp acknowledged_stream_cursor_value(event) do
    event
    |> acknowledged_stream_cursor_candidates()
    |> Enum.find_value(fn
      cursor when is_map(cursor) -> cursor
      _cursor -> nil
    end)
  end

  defp acknowledged_stream_cursor_candidates(event) do
    pane_state = pane_state(event)

    [
      Fields.value(event, :acknowledged_stream_cursor),
      Fields.value(event, :last_acknowledged_stream_cursor),
      Map.get(pane_state, :acknowledged_stream_cursor),
      Map.get(pane_state, "acknowledged_stream_cursor"),
      Map.get(pane_state, :last_acknowledged_stream_cursor),
      Map.get(pane_state, "last_acknowledged_stream_cursor")
    ]
  end
end
