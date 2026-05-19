defmodule Ourocode.Journal.CleanupEventDecoder do
  @moduledoc """
  Decodes journal entries into cleanup recovery records.

  Cleanup events prove runtime resources were released. Completed child pane
  events are also decoded so restart recovery can keep completed session cleanup
  state even when pane retention outlives the runtime stream process. Failed
  lifecycle events are decoded as pending cleanup records so restart recovery
  can prove a later cleanup action made the replay idempotent.
  """

  alias Ourocode.Journal.CleanupRecoveryRecord

  @cleanup_types MapSet.new([:transport_cleanup, :stream_cleanup])
  @orphan_candidate_types MapSet.new([
                            :child_pane_registered,
                            :child_pane_opened,
                            :child_pane_focused,
                            :child_pane_updated
                          ])
  @completion_types MapSet.new([:child_pane_completed, :child_pane_cancelled])
  @failure_types MapSet.new([
                   :parent_call_failed,
                   :parent_call_write_failed,
                   :transport_failed,
                   :transport_decode_failed
                 ])

  @type decode_result :: {:ok, CleanupRecoveryRecord.t()} | :ignore | {:error, term()}

  @spec decode_all([map()]) :: {:ok, [CleanupRecoveryRecord.t()]} | {:error, term()}
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

  @spec decode(map()) :: decode_result()
  def decode(event) when is_map(event) do
    event = normalize_event(event)

    cond do
      cleanup_event?(event) -> decode_cleanup_event(event)
      orphan_candidate_event?(event) -> decode_orphan_candidate_event(event)
      completion_event?(event) -> decode_completion_event(event)
      failure_event?(event) -> decode_failure_event(event)
      true -> :ignore
    end
  end

  def decode(_event), do: :ignore

  defp decode_cleanup_event(event) do
    with {:ok, event_type} <- event_type(event),
         {:ok, event_seq} <- required_integer(event, :event_seq),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, occurred_at_ms} <- occurred_at_ms(event),
         {:ok, cleanup_key} <- cleanup_key(event, :prefer_child) do
      {:ok,
       recovery_record(event, %{
         event_seq: event_seq,
         event_type: event_type,
         cleanup_key: cleanup_key,
         cleanup_state: :completed,
         runtime_source: runtime_source,
         occurred_at_ms: occurred_at_ms,
         replay_action: :noop
       })}
    else
      reason -> {:error, {:invalid_cleanup_journal_event, reason, event}}
    end
  end

  defp decode_orphan_candidate_event(event) do
    with {:ok, event_type} <- event_type(event),
         {:ok, event_seq} <- required_integer(event, :event_seq),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, occurred_at_ms} <- occurred_at_ms(event),
         {:ok, cleanup_key} <- cleanup_key(event, :prefer_session) do
      {:ok,
       recovery_record(event, %{
         event_seq: event_seq,
         event_type: event_type,
         cleanup_key: cleanup_key,
         cleanup_state: :pending,
         runtime_source: runtime_source,
         occurred_at_ms: occurred_at_ms,
         replay_action: :release_runtime_resources
       })}
    else
      reason -> {:error, {:invalid_cleanup_journal_event, reason, event}}
    end
  end

  defp decode_completion_event(event) do
    with {:ok, event_type} <- event_type(event),
         {:ok, event_seq} <- required_integer(event, :event_seq),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, occurred_at_ms} <- occurred_at_ms(event),
         {:ok, cleanup_key} <- cleanup_key(event, :prefer_child) do
      {:ok,
       recovery_record(event, %{
         event_seq: event_seq,
         event_type: event_type,
         cleanup_key: cleanup_key,
         cleanup_state: :completed,
         runtime_source: runtime_source,
         occurred_at_ms: occurred_at_ms,
         replay_action: :noop
       })}
    else
      reason -> {:error, {:invalid_cleanup_journal_event, reason, event}}
    end
  end

  defp decode_failure_event(event) do
    with {:ok, event_type} <- event_type(event),
         {:ok, event_seq} <- required_integer(event, :event_seq),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, occurred_at_ms} <- occurred_at_ms(event),
         {:ok, cleanup_key} <- cleanup_key(event, :prefer_child) do
      {:ok,
       recovery_record(event, %{
         event_seq: event_seq,
         event_type: event_type,
         cleanup_key: cleanup_key,
         cleanup_state: :pending,
         runtime_source: runtime_source,
         occurred_at_ms: occurred_at_ms,
         replay_action: :release_runtime_resources
       })}
    else
      reason -> {:error, {:invalid_cleanup_journal_event, reason, event}}
    end
  end

  defp recovery_record(event, attrs) do
    %CleanupRecoveryRecord{
      event_seq: attrs.event_seq,
      event_type: attrs.event_type,
      cleanup_key: attrs.cleanup_key,
      cleanup_state: attrs.cleanup_state,
      cleanup_reason: atom_value(event, :cleanup_reason),
      stream_kind: atom_value(event, :stream_kind),
      parent_call_id: string_value(event, :parent_call_id),
      child_id: string_value(event, :child_id),
      session_id: session_id(event),
      pane_id: string_value(event, :pane_id),
      runtime_source: attrs.runtime_source,
      transport: transport(event),
      external_ids: map_value(event, :external_ids, %{}),
      stream_cursor: map_value(event, :stream_cursor, %{}),
      pane_state: map_value(event, :pane_state, %{}),
      released_resources: map_value(event, :released_resources, %{}),
      stale_cleanup_timeout_ms: integer_value(event, :stale_cleanup_timeout_ms),
      stream_subscription_cleanup_timeout_ms:
        integer_value(event, :stream_subscription_cleanup_timeout_ms),
      cleanup_started_monotonic_ms: integer_value(event, :cleanup_started_monotonic_ms),
      idempotency_key: idempotency_key(event, attrs.cleanup_key),
      replay_action: replay_action(event, attrs.replay_action),
      occurred_at_ms: attrs.occurred_at_ms,
      source_event: event
    }
  end

  defp cleanup_event?(event) do
    case event_type(event) do
      {:ok, type} -> MapSet.member?(@cleanup_types, type)
      :error -> false
    end
  end

  defp orphan_candidate_event?(event) do
    case event_type(event) do
      {:ok, type} -> MapSet.member?(@orphan_candidate_types, type)
      :error -> false
    end
  end

  defp completion_event?(event) do
    case event_type(event) do
      {:ok, type} -> MapSet.member?(@completion_types, type)
      :error -> false
    end
  end

  defp failure_event?(event) do
    case event_type(event) do
      {:ok, type} -> MapSet.member?(@failure_types, type)
      :error -> false
    end
  end

  defp event_type(event) do
    case value(event, :type) || value(event, :event_type) do
      type when is_atom(type) ->
        if MapSet.member?(known_event_types(), type) do
          {:ok, type}
        else
          :error
        end

      type when is_binary(type) ->
        known_type(String.trim(type))

      _type ->
        :error
    end
  end

  defp known_type(type) do
    known_event_types()
    |> Enum.find_value(:error, fn known ->
      if Atom.to_string(known) == type, do: {:ok, known}
    end)
  end

  defp known_event_types do
    @cleanup_types
    |> MapSet.union(@orphan_candidate_types)
    |> MapSet.union(@completion_types)
    |> MapSet.union(@failure_types)
  end

  defp cleanup_key(event, preference) do
    cond do
      string_value(event, :idempotency_key) ->
        {:ok, string_value(event, :idempotency_key)}

      preference == :prefer_session && session_id(event) ->
        {:ok, "session:" <> session_id(event)}

      string_value(event, :child_id) ->
        {:ok, "child:" <> string_value(event, :child_id)}

      session_id(event) ->
        {:ok, "session:" <> session_id(event)}

      string_value(event, :parent_call_id) && transport(event) ->
        {:ok,
         "transport:" <> Atom.to_string(transport(event)) <> ":" <> string_value(event, :parent_call_id)}

      true ->
        {:error, :missing_cleanup_identity}
    end
  end

  defp idempotency_key(event, cleanup_key) do
    string_value(event, :idempotency_key) || cleanup_key
  end

  defp replay_action(event, fallback) do
    case atom_value(event, :replay_action) do
      action when action in [:noop, :release_runtime_resources] -> action
      _action -> fallback
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

  defp transport(event) do
    case value(event, :transport) do
      transport when transport in [:stdio, :streamable_http, :sse] -> transport
      "stdio" -> :stdio
      "streamable_http" -> :streamable_http
      "sse" -> :sse
      _transport -> nil
    end
  end

  defp session_id(event) do
    string_value(event, :session_id) || Map.get(map_value(event, :external_ids, %{}), "session_id")
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
  defp top_level_key("cleanup_action"), do: :cleanup_action
  defp top_level_key("cleanup_reason"), do: :cleanup_reason
  defp top_level_key("cleanup_started_monotonic_ms"), do: :cleanup_started_monotonic_ms
  defp top_level_key("cleanup_state"), do: :cleanup_state
  defp top_level_key("created_at_ms"), do: :created_at_ms
  defp top_level_key("event_seq"), do: :event_seq
  defp top_level_key("event_type"), do: :event_type
  defp top_level_key("external_ids"), do: :external_ids
  defp top_level_key("error"), do: :error
  defp top_level_key("error_details"), do: :error_details
  defp top_level_key("idempotency_key"), do: :idempotency_key
  defp top_level_key("occurred_at_ms"), do: :occurred_at_ms
  defp top_level_key("pane_id"), do: :pane_id
  defp top_level_key("pane_state"), do: :pane_state
  defp top_level_key("parent_call_id"), do: :parent_call_id
  defp top_level_key("released_resources"), do: :released_resources
  defp top_level_key("replay_action"), do: :replay_action
  defp top_level_key("runtime_source"), do: :runtime_source
  defp top_level_key("session_id"), do: :session_id
  defp top_level_key("stale_cleanup_timeout_ms"), do: :stale_cleanup_timeout_ms
  defp top_level_key("stream_cursor"), do: :stream_cursor
  defp top_level_key("stream_kind"), do: :stream_kind
  defp top_level_key("stream_subscription_cleanup_timeout_ms") do
    :stream_subscription_cleanup_timeout_ms
  end
  defp top_level_key("transport"), do: :transport
  defp top_level_key("type"), do: :type
  defp top_level_key("updated_at_ms"), do: :updated_at_ms
  defp top_level_key(key), do: key

  defp value(event, key) do
    Map.get(event, key) || Map.get(event, Atom.to_string(key))
  end

  defp map_value(event, key, default) do
    case value(event, key) do
      map when is_map(map) -> map
      _value -> default
    end
  end

  defp string_value(event, key) do
    case value(event, key) do
      nil -> nil
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp integer_value(event, key) do
    case value(event, key) do
      value when is_integer(value) -> value
      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _other -> nil
        end

      _value ->
        nil
    end
  end

  defp atom_value(event, key) do
    case value(event, key) do
      value when is_atom(value) -> value
      value when is_binary(value) -> string_to_existing_cleanup_atom(value)
      _value -> nil
    end
  end

  defp string_to_existing_cleanup_atom("already_completed"), do: :already_completed
  defp string_to_existing_cleanup_atom("cancelled"), do: :cancelled
  defp string_to_existing_cleanup_atom("canceled"), do: :canceled
  defp string_to_existing_cleanup_atom("child"), do: :child
  defp string_to_existing_cleanup_atom("completed"), do: :completed
  defp string_to_existing_cleanup_atom("idle_timeout"), do: :idle_timeout
  defp string_to_existing_cleanup_atom("noop"), do: :noop
  defp string_to_existing_cleanup_atom("operation_timeout"), do: :operation_timeout
  defp string_to_existing_cleanup_atom("release_runtime_resources"), do: :release_runtime_resources
  defp string_to_existing_cleanup_atom("session"), do: :session
  defp string_to_existing_cleanup_atom("transport"), do: :transport
  defp string_to_existing_cleanup_atom(_value), do: nil
end
