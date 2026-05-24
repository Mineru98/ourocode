defmodule Ourocode.Runtime.Stream.CleanupEvent do
  @moduledoc """
  Cleanup lifecycle event payload builders for runtime streams.
  """

  @spec idle_timeout(map(), integer(), non_neg_integer(), map()) :: map()
  def idle_timeout(state, now_ms, elapsed_ms, released_resources) do
    state
    |> base(now_ms, released_resources)
    |> Map.merge(%{
      cleanup_reason: :idle_timeout,
      idle_elapsed_ms: elapsed_ms
    })
  end

  @spec operation_timeout(map(), integer(), non_neg_integer(), map()) :: map()
  def operation_timeout(state, now_ms, elapsed_ms, released_resources) do
    state
    |> base(now_ms, released_resources)
    |> Map.merge(%{
      cleanup_reason: :operation_timeout,
      operation_id: state.stream_active_operation_id,
      operation_elapsed_ms: elapsed_ms,
      operation_timeout_ms:
        state.stream_active_operation_timeout_ms || state.stream_operation_timeout_ms,
      operation_started_monotonic_ms: state.stream_operation_started_monotonic_ms
    })
  end

  @spec timeout_termination(map()) :: map()
  def timeout_termination(cleanup) when is_map(cleanup) do
    cleanup
    |> Map.put(:lifecycle_type, :stream_terminated)
    |> Map.put(:exit_state, :normal)
    |> Map.put(:exit_reason, Map.fetch!(cleanup, :cleanup_reason))
  end

  defp base(state, now_ms, released_resources) do
    %{
      stream_kind: state.stream_kind,
      runtime_source: Map.get(state, :runtime_source),
      transport: Map.get(state, :transport),
      parent_call_id: Map.get(state, :parent_call_id),
      child_id: Map.get(state, :child_id),
      session_id: Map.get(state, :session_id),
      external_ids: Map.get(state, :external_ids, %{}),
      stream_cursor: Map.get(state, :stream_cursor, %{}),
      stale_cleanup_timeout_ms: state.stream_stale_cleanup_timeout_ms,
      stream_subscription_cleanup_timeout_ms: state.stream_subscription_cleanup_timeout_ms,
      last_activity_monotonic_ms: state.stream_last_activity_monotonic_ms,
      cleanup_started_monotonic_ms: now_ms,
      released_resources: released_resources
    }
  end
end
