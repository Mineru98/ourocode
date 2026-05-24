defmodule Ourocode.Journal.RelationshipEventDecoder do
  @moduledoc """
  Decodes persisted journal relationship events into typed recovery records.

  Relationship events are records that tie one local parent MCP call to one
  child agent/session. Both runtime lifecycle events with child IDs and
  dashboard child-pane lifecycle records are accepted.
  """

  alias Ourocode.Journal.RelationshipEventFields, as: Fields
  alias Ourocode.Journal.RelationshipEventType
  alias Ourocode.Journal.RelationshipRecoveryFields
  alias Ourocode.Journal.RelationshipRecoveryRecord
  alias Ourocode.MCP.ChildSessionCreationParser

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
    event = Fields.normalize(event)

    case RelationshipEventType.category(event) do
      {:ok, :pane_lifecycle, event_type} ->
        decode_pane_lifecycle_event(event, event_type)

      {:ok, :runtime_relationship, event_type} ->
        decode_runtime_relationship_event(event, event_type)

      :error ->
        :ignore
    end
  end

  def decode(_event), do: :ignore

  defp decode_pane_lifecycle_event(event, event_type) do
    with {:ok, parent_call_id} <- required_string(event, :parent_call_id),
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
         pane_id: RelationshipRecoveryFields.pane_id(event, child_id),
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

  defp decode_runtime_relationship_event(event, event_type) do
    with {:ok, extraction} <- child_extraction(event),
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
         pane_id:
           RelationshipRecoveryFields.pane_id(event, extraction.child_id, extraction.pane_key),
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
      external_ids: RelationshipRecoveryFields.external_ids(event, attrs.child_id),
      stream_cursor:
        RelationshipRecoveryFields.stream_cursor(
          event,
          attrs.transport,
          attrs.event_seq,
          attrs.child_id
        ),
      acknowledged_stream_cursor:
        RelationshipRecoveryFields.acknowledged_stream_cursor(
          event,
          attrs.transport,
          attrs.event_seq,
          attrs.child_id
        ),
      pane_state: RelationshipRecoveryFields.pane_state(event),
      occurred_at_ms: attrs.occurred_at_ms,
      created_at_ms: Fields.integer_value(event, :created_at_ms),
      updated_at_ms: Fields.integer_value(event, :updated_at_ms),
      status: RelationshipRecoveryFields.status(event, attrs.event_type),
      child_id_source: attrs.child_id_source,
      payload_path: attrs.payload_path,
      source_event: event
    }
  end

  defp child_extraction(event) do
    case ChildSessionCreationParser.extract(event) do
      {:ok, extraction} -> {:ok, extraction}
      {:unresolved, unresolved} -> {:error, unresolved}
      :ignore -> :ignore
    end
  end

  defp required_string(event, key) do
    case Fields.string_value(event, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_required_string, key}}
    end
  end

  defp required_integer(event, key) do
    case Fields.integer_value(event, key) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, {:missing_required_integer, key}}
    end
  end

  defp occurred_at_ms(event) do
    case Fields.integer_value(event, :occurred_at_ms) ||
           Fields.integer_value(event, :updated_at_ms) ||
           Fields.integer_value(event, :created_at_ms) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, {:missing_required_integer, :occurred_at_ms}}
    end
  end

  defp required_transport(event), do: Fields.transport(event)
end
