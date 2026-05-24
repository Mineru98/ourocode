defmodule Ourocode.Journal.CleanupState do
  @moduledoc """
  Merges recovered cleanup state snapshots.

  Cleanup recovery can see several journal records for the same cleanup key.
  This module owns the pure merge rules that preserve completed/idempotent
  state and the strongest resource-release evidence.
  """

  alias Ourocode.Journal.CleanupEventFields, as: Fields

  @spec merge(map(), map()) :: map()
  def merge(existing, incoming) when is_map(existing) and is_map(incoming) do
    %{
      existing
      | cleanup_state: strongest_cleanup_state(existing.cleanup_state, incoming.cleanup_state),
        cleanup_reason: incoming.cleanup_reason || existing.cleanup_reason,
        stream_kind: incoming.stream_kind || existing.stream_kind,
        parent_call_id: incoming.parent_call_id || existing.parent_call_id,
        child_id: incoming.child_id || existing.child_id,
        session_id: incoming.session_id || existing.session_id,
        pane_id: incoming.pane_id || existing.pane_id,
        runtime_source: incoming.runtime_source || existing.runtime_source,
        transport: incoming.transport || existing.transport,
        external_ids: Map.merge(existing.external_ids || %{}, incoming.external_ids || %{}),
        stream_cursor: Map.merge(existing.stream_cursor || %{}, incoming.stream_cursor || %{}),
        pane_state: Map.merge(existing.pane_state || %{}, incoming.pane_state || %{}),
        released_resources:
          merge_resource_counts(
            existing.released_resources || %{},
            incoming.released_resources || %{}
          ),
        stale_cleanup_timeout_ms:
          incoming.stale_cleanup_timeout_ms || existing.stale_cleanup_timeout_ms,
        stream_subscription_cleanup_timeout_ms:
          incoming.stream_subscription_cleanup_timeout_ms ||
            existing.stream_subscription_cleanup_timeout_ms,
        cleanup_started_monotonic_ms:
          latest(existing.cleanup_started_monotonic_ms, incoming.cleanup_started_monotonic_ms),
        idempotency_key: incoming.idempotency_key || existing.idempotency_key,
        replay_action: strongest_replay_action(existing.replay_action, incoming.replay_action),
        latest_event_seq: max(existing.latest_event_seq, incoming.latest_event_seq),
        event_seqs: existing.event_seqs ++ incoming.event_seqs,
        source_event_types: existing.source_event_types ++ incoming.source_event_types,
        occurred_at_ms: incoming.occurred_at_ms || existing.occurred_at_ms
    }
  end

  @spec strongest_cleanup_state(atom() | nil, atom() | nil) :: atom() | nil
  def strongest_cleanup_state(:completed, _incoming), do: :completed
  def strongest_cleanup_state(_existing, :completed), do: :completed
  def strongest_cleanup_state(existing, _incoming), do: existing

  @spec strongest_replay_action(atom() | nil, atom() | nil) :: atom() | nil
  def strongest_replay_action(:noop, _incoming), do: :noop
  def strongest_replay_action(_existing, :noop), do: :noop
  def strongest_replay_action(existing, _incoming), do: existing

  @spec merge_resource_counts(map(), map()) :: map()
  def merge_resource_counts(existing, incoming) when is_map(existing) and is_map(incoming) do
    Map.merge(existing, incoming, fn _key, left, right ->
      if is_integer(left) and is_integer(right), do: max(left, right), else: right
    end)
  end

  @spec cleanup_key(map(), :prefer_child | :prefer_session) ::
          {:ok, String.t()} | {:error, atom()}
  def cleanup_key(event, preference) when is_map(event) do
    cond do
      Fields.string_value(event, :idempotency_key) ->
        {:ok, Fields.string_value(event, :idempotency_key)}

      preference == :prefer_session && Fields.session_id(event) ->
        {:ok, "session:" <> Fields.session_id(event)}

      Fields.string_value(event, :child_id) ->
        {:ok, "child:" <> Fields.string_value(event, :child_id)}

      Fields.session_id(event) ->
        {:ok, "session:" <> Fields.session_id(event)}

      Fields.string_value(event, :parent_call_id) && Fields.transport(event) ->
        {:ok,
         "transport:" <>
           Atom.to_string(Fields.transport(event)) <>
           ":" <> Fields.string_value(event, :parent_call_id)}

      true ->
        {:error, :missing_cleanup_identity}
    end
  end

  @spec idempotency_key(map(), String.t()) :: String.t()
  def idempotency_key(event, cleanup_key) when is_map(event) and is_binary(cleanup_key) do
    Fields.string_value(event, :idempotency_key) || cleanup_key
  end

  @spec replay_action(map(), :noop | :release_runtime_resources) ::
          :noop | :release_runtime_resources
  def replay_action(event, fallback) when is_map(event) do
    case Fields.atom_value(event, :replay_action) do
      action when action in [:noop, :release_runtime_resources] -> action
      _action -> fallback
    end
  end

  defp latest(nil, value), do: value
  defp latest(value, nil), do: value
  defp latest(left, right), do: max(left, right)
end
