defmodule Ourocode.Journal.RelationshipEventDecoder do
  @moduledoc """
  Decodes persisted journal relationship events into typed recovery records.

  Relationship events are records that tie one local parent MCP call to one
  child agent/session. Both runtime lifecycle events with child IDs and
  dashboard child-pane lifecycle records are accepted.
  """

  alias Ourocode.Journal.RelationshipRecoveryRecord
  alias Ourocode.MCP.ChildSessionCreationParser

  @pane_lifecycle_types MapSet.new([
                          :child_pane_registered,
                          :child_pane_opened,
                          :child_pane_focused,
                          :child_pane_updated,
                          :child_pane_completed
                        ])

  @runtime_relationship_types MapSet.new([
                                :parent_call_started,
                                :parent_call_event,
                                :parent_call_result
                              ])

  @typedoc "Decode result for a single journal entry."
  @type decode_result :: {:ok, RelationshipRecoveryRecord.t()} | :ignore | {:error, term()}

  @doc """
  Decodes all relationship records from restored journal entries.
  """
  @spec decode_all([map()]) :: {:ok, [RelationshipRecoveryRecord.t()]} | {:error, term()}
  def decode_all(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case decode(entry) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        :ignore -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Decodes one restored journal entry into a relationship recovery record.
  """
  @spec decode(map()) :: decode_result()
  def decode(event) when is_map(event) do
    event = normalize_event(event)

    cond do
      pane_lifecycle_event?(event) ->
        decode_pane_lifecycle_event(event)

      runtime_relationship_event?(event) ->
        decode_runtime_relationship_event(event)

      true ->
        :ignore
    end
  end

  def decode(_event), do: :ignore

  defp decode_pane_lifecycle_event(event) do
    with {:ok, event_type} <- relationship_type(event),
         {:ok, parent_call_id} <- required_string(event, :parent_call_id),
         {:ok, child_id} <- required_string(event, :child_id),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, transport} <- required_transport(event),
         {:ok, event_seq} <- required_integer(event, :event_seq),
         {:ok, occurred_at_ms} <- occurred_at_ms(event) do
      {:ok,
       recovery_record(event, %{
         event_type: event_type,
         parent_call_id: parent_call_id,
         child_id: child_id,
         pane_id: pane_id(event, child_id),
         runtime_source: runtime_source,
         transport: transport,
         event_seq: event_seq,
         occurred_at_ms: occurred_at_ms,
         child_id_source: :pane_lifecycle,
         payload_path: :event
       })}
    else
      reason -> {:error, {:invalid_relationship_journal_event, reason, event}}
    end
  end

  defp decode_runtime_relationship_event(event) do
    with {:ok, event_type} <- relationship_type(event),
         {:ok, extraction} <- child_extraction(event),
         {:ok, parent_call_id} <- required_string(event, :parent_call_id),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, transport} <- required_transport(event),
         {:ok, event_seq} <- required_integer(event, :event_seq),
         {:ok, occurred_at_ms} <- occurred_at_ms(event) do
      {:ok,
       recovery_record(event, %{
         event_type: event_type,
         parent_call_id: parent_call_id,
         child_id: extraction.child_id,
         pane_id: pane_id(event, extraction.child_id, extraction.pane_key),
         runtime_source: runtime_source,
         transport: transport,
         event_seq: event_seq,
         occurred_at_ms: occurred_at_ms,
         child_id_source: extraction.source,
         payload_path: extraction.payload_path
       })}
    else
      :ignore -> :ignore
      reason -> {:error, {:invalid_relationship_journal_event, reason, event}}
    end
  end

  defp recovery_record(event, attrs) do
    %RelationshipRecoveryRecord{
      event_seq: attrs.event_seq,
      event_type: attrs.event_type,
      parent_call_id: attrs.parent_call_id,
      child_id: attrs.child_id,
      pane_id: attrs.pane_id,
      runtime_source: attrs.runtime_source,
      transport: attrs.transport,
      external_ids: external_ids(event, attrs.child_id),
      stream_cursor: stream_cursor(event, attrs.transport, attrs.event_seq, attrs.child_id),
      acknowledged_stream_cursor:
        acknowledged_stream_cursor(event, attrs.transport, attrs.event_seq, attrs.child_id),
      pane_state: pane_state(event),
      occurred_at_ms: attrs.occurred_at_ms,
      created_at_ms: integer_value(event, :created_at_ms),
      updated_at_ms: integer_value(event, :updated_at_ms),
      status: status(event, attrs.event_type),
      child_id_source: attrs.child_id_source,
      payload_path: attrs.payload_path,
      source_event: event
    }
  end

  defp pane_lifecycle_event?(event) do
    case relationship_type(event) do
      {:ok, type} -> MapSet.member?(@pane_lifecycle_types, type)
      :error -> false
    end
  end

  defp runtime_relationship_event?(event) do
    case relationship_type(event) do
      {:ok, type} -> MapSet.member?(@runtime_relationship_types, type)
      :error -> false
    end
  end

  defp relationship_type(event) do
    case value(event, :type) || value(event, :event_type) do
      type when is_atom(type) ->
        cond do
          MapSet.member?(@pane_lifecycle_types, type) -> {:ok, type}
          MapSet.member?(@runtime_relationship_types, type) -> {:ok, type}
          true -> :error
        end

      type when is_binary(type) ->
        known_type(String.trim(type))

      _type ->
        :error
    end
  end

  defp known_type(type) do
    @pane_lifecycle_types
    |> MapSet.union(@runtime_relationship_types)
    |> Enum.find_value(:error, fn known ->
      if Atom.to_string(known) == type, do: {:ok, known}
    end)
  end

  defp child_extraction(event) do
    case ChildSessionCreationParser.extract(event) do
      {:ok, extraction} -> {:ok, extraction}
      {:unresolved, unresolved} -> {:error, unresolved}
      :ignore -> :ignore
    end
  end

  defp required_string(event, key) do
    case string_value(event, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_required_string, key}}
    end
  end

  defp required_integer(event, key) do
    case integer_value(event, key) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, {:missing_required_integer, key}}
    end
  end

  defp occurred_at_ms(event) do
    case integer_value(event, :occurred_at_ms) ||
           integer_value(event, :updated_at_ms) ||
           integer_value(event, :created_at_ms) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, {:missing_required_integer, :occurred_at_ms}}
    end
  end

  defp required_transport(event) do
    case value(event, :transport) do
      transport when transport in [:stdio, :streamable_http, :sse] -> {:ok, transport}
      "stdio" -> {:ok, :stdio}
      "streamable_http" -> {:ok, :streamable_http}
      "sse" -> {:ok, :sse}
      _transport -> {:error, :invalid_transport}
    end
  end

  defp external_ids(event, child_id) do
    event
    |> map_value(:external_ids, %{})
    |> Map.put_new("childID", child_id)
  end

  defp stream_cursor(event, transport, event_seq, child_id) do
    event
    |> map_value(:stream_cursor, %{})
    |> Map.merge(%{
      transport: transport,
      child_id: child_id,
      event_seq: event_seq
    })
  end

  defp acknowledged_stream_cursor(event, transport, event_seq, child_id) do
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
      value(event, :acknowledged_stream_cursor),
      value(event, :last_acknowledged_stream_cursor),
      Map.get(pane_state, :acknowledged_stream_cursor),
      Map.get(pane_state, "acknowledged_stream_cursor"),
      Map.get(pane_state, :last_acknowledged_stream_cursor),
      Map.get(pane_state, "last_acknowledged_stream_cursor")
    ]
  end

  defp pane_state(event), do: map_value(event, :pane_state, %{})

  defp pane_id(event, child_id) do
    string_value(event, :pane_id) || string_value(event, :id) || "child-session:" <> child_id
  end

  defp pane_id(event, child_id, extracted_pane_key) do
    string_value(event, :pane_id) || string_value(event, :id) || extracted_pane_key ||
      "child-session:" <> child_id
  end

  defp status(event, event_type) do
    case value(event, :status) do
      status when status in [:working, :completed] -> status
      "working" -> :working
      "completed" -> :completed
      _status when event_type == :child_pane_completed -> :completed
      _status -> nil
    end
  end

  defp normalize_event(%_{} = event), do: event |> Map.from_struct() |> normalize_event()

  defp normalize_event(event) do
    Map.new(event, fn {key, value} ->
      {normalize_key(key), normalize_nested(value)}
    end)
  end

  defp normalize_nested(%{} = map) do
    Map.new(map, fn {key, value} -> {key, normalize_nested(value)} end)
  end

  defp normalize_nested(list) when is_list(list), do: Enum.map(list, &normalize_nested/1)
  defp normalize_nested(value), do: value

  defp normalize_key(key) when is_binary(key), do: top_level_key(key)
  defp normalize_key(key), do: key

  defp top_level_key("child_id"), do: :child_id
  defp top_level_key("created_at_ms"), do: :created_at_ms
  defp top_level_key("event_seq"), do: :event_seq
  defp top_level_key("event_type"), do: :event_type
  defp top_level_key("external_ids"), do: :external_ids
  defp top_level_key("acknowledged_stream_cursor"), do: :acknowledged_stream_cursor
  defp top_level_key("last_acknowledged_stream_cursor"), do: :last_acknowledged_stream_cursor
  defp top_level_key("id"), do: :id
  defp top_level_key("occurred_at_ms"), do: :occurred_at_ms
  defp top_level_key("pane_id"), do: :pane_id
  defp top_level_key("pane_state"), do: :pane_state
  defp top_level_key("parent_call_id"), do: :parent_call_id
  defp top_level_key("runtime_source"), do: :runtime_source
  defp top_level_key("stream_cursor"), do: :stream_cursor
  defp top_level_key("transport"), do: :transport
  defp top_level_key("type"), do: :type
  defp top_level_key("updated_at_ms"), do: :updated_at_ms
  defp top_level_key(key), do: key

  defp value(event, key), do: Map.get(event, key) || Map.get(event, Atom.to_string(key))

  defp string_value(event, key) do
    case value(event, key) do
      value when is_binary(value) -> String.trim(value)
      value when is_integer(value) -> Integer.to_string(value)
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _value -> nil
    end
  end

  defp integer_value(event, key) do
    case value(event, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} -> integer
          _parse_error -> nil
        end

      _value ->
        nil
    end
  end

  defp map_value(event, key, default) do
    case value(event, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end
end
