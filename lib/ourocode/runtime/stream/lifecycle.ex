defmodule Ourocode.Runtime.Stream.Lifecycle do
  @moduledoc """
  Shared activity and cleanup lifecycle for supervised runtime streams.

  Stream processes keep the local recovery state Elixir owns: activity
  timestamps, stale detection, cleanup notification, and timeout metadata. The
  external runtime still owns authoritative session/job status.
  """

  alias Ourocode.Runtime.Stream.CleanupEvent
  alias Ourocode.Runtime.Stream.LifecycleRouting
  alias Ourocode.Runtime.Stream.LifecycleState
  alias Ourocode.Runtime.Stream.Resources
  alias Ourocode.Runtime.Stream.Telemetry
  alias Ourocode.Runtime.Stream.Timers

  @type stale_cleanup :: %{
          required(:cleanup_reason) => :idle_timeout | :operation_timeout,
          required(:stream_kind) => atom(),
          optional(:idle_elapsed_ms) => non_neg_integer(),
          optional(:operation_elapsed_ms) => non_neg_integer(),
          optional(:operation_timeout_ms) => pos_integer(),
          optional(:stream_subscription_cleanup_timeout_ms) => pos_integer(),
          optional(:operation_id) => term(),
          required(:stale_cleanup_timeout_ms) => pos_integer(),
          required(:last_activity_monotonic_ms) => integer(),
          required(:cleanup_started_monotonic_ms) => integer(),
          optional(:lifecycle_type) => :stream_terminated,
          optional(:exit_state) => :normal,
          required(:released_resources) => %{
            required(:process_handles) => non_neg_integer(),
            required(:subscriptions) => non_neg_integer(),
            required(:registered_buffers) => non_neg_integer(),
            required(:ets_entries) => non_neg_integer(),
            required(:pending_events) => non_neg_integer()
          }
        }

  @spec fields(keyword()) :: map()
  def fields(opts) when is_list(opts) do
    now_ms = Keyword.get(opts, :stream_now_ms, monotonic_ms())
    LifecycleState.fields(opts, now_ms)
  end

  @spec register_resource(map(), :process_handle | :subscription | :buffer, term()) ::
          {:ok, map()} | {{:error, :unsupported_resource_kind}, map()}
  def register_resource(state, :process_handle, resource) do
    {:ok, state |> touch() |> Map.update!(:stream_process_handles, &[resource | &1])}
  end

  def register_resource(state, :subscription, resource) do
    {:ok, state |> touch() |> Map.update!(:stream_subscriptions, &[resource | &1])}
  end

  def register_resource(state, :buffer, resource) do
    {:ok, state |> touch() |> Map.update!(:stream_registered_buffers, &[resource | &1])}
  end

  def register_resource(state, _kind, _resource) do
    {{:error, :unsupported_resource_kind}, state}
  end

  @spec touch(map()) :: map()
  def touch(state) do
    now_ms = monotonic_ms()

    state
    |> Timers.cancel_idle()
    |> Map.put(:stream_status, :active)
    |> Map.put(:stream_last_activity_monotonic_ms, now_ms)
    |> Map.put(:stream_cleanup_started_monotonic_ms, nil)
    |> Map.put(:stream_cleanup_reason, nil)
    |> Map.put(
      :stream_idle_timer_ref,
      Timers.schedule_idle(state.stream_stale_cleanup_timeout_ms, now_ms)
    )
  end

  @spec begin_operation(map(), term(), keyword()) :: map()
  def begin_operation(state, operation_id, opts \\ []) do
    now_ms = monotonic_ms()
    timeout_ms = Keyword.get(opts, :operation_timeout_ms, state.stream_operation_timeout_ms)
    deadline_ms = now_ms + timeout_ms

    state
    |> touch()
    |> Timers.cancel_operation()
    |> Map.put(:stream_status, :active)
    |> Map.put(:stream_active_operation_timeout_ms, timeout_ms)
    |> Map.put(:stream_active_operation_id, operation_id)
    |> Map.put(:stream_operation_started_monotonic_ms, now_ms)
    |> Map.put(:stream_operation_deadline_monotonic_ms, deadline_ms)
    |> Map.put(
      :stream_operation_timer_ref,
      Timers.schedule_operation(timeout_ms, operation_id, deadline_ms)
    )
  end

  @spec complete_operation(map(), term()) ::
          {:ok, map()} | {{:error, :operation_not_active}, map()}
  def complete_operation(%{stream_active_operation_id: operation_id} = state, operation_id) do
    state =
      state
      |> Timers.cancel_operation()
      |> Map.put(:stream_active_operation_id, nil)
      |> Map.put(:stream_active_operation_timeout_ms, nil)
      |> Map.put(:stream_operation_started_monotonic_ms, nil)
      |> Map.put(:stream_operation_deadline_monotonic_ms, nil)
      |> Map.put(:stream_operation_timer_ref, nil)

    {:ok, touch(state)}
  end

  def complete_operation(state, _operation_id), do: {{:error, :operation_not_active}, state}

  @spec handle_idle_timeout(map(), integer()) ::
          {:noreply, map()} | {:stop, :normal, map()}
  def handle_idle_timeout(state, expected_last_activity_ms) do
    if expected_last_activity_ms == state.stream_last_activity_monotonic_ms do
      maybe_cleanup_stale(state)
    else
      {:noreply, state}
    end
  end

  @spec handle_operation_timeout(map(), term(), integer()) ::
          {:noreply, map()} | {:stop, :normal, map()}
  def handle_operation_timeout(state, operation_id, deadline_ms) do
    if state.stream_active_operation_id == operation_id and
         state.stream_operation_deadline_monotonic_ms == deadline_ms do
      maybe_timeout_operation(state)
    else
      {:noreply, state}
    end
  end

  defp maybe_cleanup_stale(state) do
    now_ms = monotonic_ms()
    elapsed_ms = max(now_ms - state.stream_last_activity_monotonic_ms, 0)

    if elapsed_ms >= state.stream_stale_cleanup_timeout_ms do
      {state, released_resources} = Resources.release_registered(state)
      cleanup = CleanupEvent.idle_timeout(state, now_ms, elapsed_ms, released_resources)
      Telemetry.emit_cleanup(state, cleanup)
      LifecycleRouting.route_cleanup(state, cleanup)
      LifecycleRouting.route_timeout_termination(state, cleanup)

      state =
        state
        |> Map.put(:stream_status, :stale)
        |> Map.put(:stream_cleanup_started_monotonic_ms, now_ms)
        |> Map.put(:stream_cleanup_reason, :idle_timeout)
        |> Map.put(:stream_idle_timer_ref, nil)

      case state.stream_cleanup_action do
        :stop -> {:stop, :normal, state}
        :mark_stale -> {:noreply, state}
      end
    else
      remaining_ms = max(state.stream_stale_cleanup_timeout_ms - elapsed_ms, 1)

      state =
        Map.put(
          state,
          :stream_idle_timer_ref,
          Timers.schedule_idle(remaining_ms, state.stream_last_activity_monotonic_ms)
        )

      {:noreply, state}
    end
  end

  defp maybe_timeout_operation(state) do
    now_ms = monotonic_ms()

    if now_ms >= state.stream_operation_deadline_monotonic_ms do
      elapsed_ms = max(now_ms - state.stream_operation_started_monotonic_ms, 0)
      {state, released_resources} = Resources.release_registered(state)
      cleanup = CleanupEvent.operation_timeout(state, now_ms, elapsed_ms, released_resources)
      Telemetry.emit_cleanup(state, cleanup)
      LifecycleRouting.route_operation_timeout(state, cleanup)
      LifecycleRouting.route_cleanup(state, cleanup)
      LifecycleRouting.route_timeout_termination(state, cleanup)

      state =
        state
        |> Timers.cancel_idle()
        |> Timers.cancel_operation()
        |> Map.put(:stream_status, :stale)
        |> Map.put(:stream_cleanup_started_monotonic_ms, now_ms)
        |> Map.put(:stream_cleanup_reason, :operation_timeout)
        |> Map.put(:stream_idle_timer_ref, nil)
        |> Map.put(:stream_operation_timer_ref, nil)
        |> Map.update!(:stream_operation_timeout_count, &(&1 + 1))

      case state.stream_cleanup_action do
        :stop -> {:stop, :normal, state}
        :mark_stale -> {:noreply, state}
      end
    else
      remaining_ms = max(state.stream_operation_deadline_monotonic_ms - now_ms, 1)

      state =
        Map.put(
          state,
          :stream_operation_timer_ref,
          Timers.schedule_operation(
            remaining_ms,
            state.stream_active_operation_id,
            state.stream_operation_deadline_monotonic_ms
          )
        )

      {:noreply, state}
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
