defmodule Ourocode.Runtime.Stream.Lifecycle do
  @moduledoc """
  Shared activity and cleanup lifecycle for supervised runtime streams.

  Stream processes keep the local recovery state Elixir owns: activity
  timestamps, stale detection, cleanup notification, and timeout metadata. The
  external runtime still owns authoritative session/job status.
  """

  alias Ourocode.Config
  alias Ourocode.Runtime.Stream.Mailbox
  alias Ourocode.Runtime.Stream.Telemetry

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
    config = Config.defaults()
    now_ms = Keyword.get(opts, :stream_now_ms, monotonic_ms())
    timeout_ms = Keyword.get(opts, :stale_cleanup_timeout_ms, config.stale_cleanup_timeout_ms)

    %{
      stream_status: :active,
      stream_last_activity_monotonic_ms: now_ms,
      stream_stale_cleanup_timeout_ms: timeout_ms,
      stream_subscription_cleanup_timeout_ms:
        Keyword.get(
          opts,
          :stream_subscription_cleanup_timeout_ms,
          config.stream_subscription_cleanup_timeout_ms
        ),
      stream_operation_timeout_ms:
        Keyword.get(opts, :operation_timeout_ms, config.operation_timeout_ms),
      stream_active_operation_timeout_ms: nil,
      stream_active_operation_id: nil,
      stream_operation_started_monotonic_ms: nil,
      stream_operation_deadline_monotonic_ms: nil,
      stream_operation_timer_ref: nil,
      stream_operation_timeout_count: 0,
      stream_lifecycle_target: Keyword.get(opts, :stream_lifecycle_target),
      stream_operation_timeout_target: Keyword.get(opts, :stream_operation_timeout_target),
      stream_cleanup_target: Keyword.get(opts, :stream_cleanup_target),
      stream_cleanup_action: Keyword.get(opts, :stream_cleanup_action, :stop),
      stream_process_handles: Keyword.get(opts, :stream_process_handles, []),
      stream_subscriptions: Keyword.get(opts, :stream_subscriptions, []),
      stream_registered_buffers: Keyword.get(opts, :stream_registered_buffers, []),
      stream_cleanup_started_monotonic_ms: nil,
      stream_cleanup_reason: nil,
      stream_idle_timer_ref: schedule_idle_timeout(timeout_ms, now_ms)
    }
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
    |> cancel_idle_timer()
    |> Map.put(:stream_status, :active)
    |> Map.put(:stream_last_activity_monotonic_ms, now_ms)
    |> Map.put(:stream_cleanup_started_monotonic_ms, nil)
    |> Map.put(:stream_cleanup_reason, nil)
    |> Map.put(
      :stream_idle_timer_ref,
      schedule_idle_timeout(state.stream_stale_cleanup_timeout_ms, now_ms)
    )
  end

  @spec begin_operation(map(), term(), keyword()) :: map()
  def begin_operation(state, operation_id, opts \\ []) do
    now_ms = monotonic_ms()
    timeout_ms = Keyword.get(opts, :operation_timeout_ms, state.stream_operation_timeout_ms)
    deadline_ms = now_ms + timeout_ms

    state
    |> touch()
    |> cancel_operation_timer()
    |> Map.put(:stream_status, :active)
    |> Map.put(:stream_active_operation_timeout_ms, timeout_ms)
    |> Map.put(:stream_active_operation_id, operation_id)
    |> Map.put(:stream_operation_started_monotonic_ms, now_ms)
    |> Map.put(:stream_operation_deadline_monotonic_ms, deadline_ms)
    |> Map.put(
      :stream_operation_timer_ref,
      schedule_operation_timeout(timeout_ms, operation_id, deadline_ms)
    )
  end

  @spec complete_operation(map(), term()) :: {:ok, map()} | {{:error, :operation_not_active}, map()}
  def complete_operation(%{stream_active_operation_id: operation_id} = state, operation_id) do
    state =
      state
      |> cancel_operation_timer()
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
      {state, released_resources} = release_registered_resources(state)
      cleanup = cleanup_event(state, now_ms, elapsed_ms, released_resources)
      Telemetry.emit_cleanup(state, cleanup)
      route_cleanup(state, cleanup)
      maybe_route_timeout_termination(state, cleanup)

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
          schedule_idle_timeout(remaining_ms, state.stream_last_activity_monotonic_ms)
        )

      {:noreply, state}
    end
  end

  defp maybe_timeout_operation(state) do
    now_ms = monotonic_ms()

    if now_ms >= state.stream_operation_deadline_monotonic_ms do
      elapsed_ms = max(now_ms - state.stream_operation_started_monotonic_ms, 0)
      {state, released_resources} = release_registered_resources(state)
      cleanup = operation_timeout_event(state, now_ms, elapsed_ms, released_resources)
      Telemetry.emit_cleanup(state, cleanup)
      route_operation_timeout(state, cleanup)
      route_cleanup(state, cleanup)
      maybe_route_timeout_termination(state, cleanup)

      state =
        state
        |> cancel_idle_timer()
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
          schedule_operation_timeout(
            remaining_ms,
            state.stream_active_operation_id,
            state.stream_operation_deadline_monotonic_ms
          )
        )

      {:noreply, state}
    end
  end

  defp cleanup_event(state, now_ms, elapsed_ms, released_resources) do
    %{
      cleanup_reason: :idle_timeout,
      stream_kind: state.stream_kind,
      runtime_source: Map.get(state, :runtime_source),
      transport: Map.get(state, :transport),
      parent_call_id: Map.get(state, :parent_call_id),
      child_id: Map.get(state, :child_id),
      session_id: Map.get(state, :session_id),
      external_ids: Map.get(state, :external_ids, %{}),
      stream_cursor: Map.get(state, :stream_cursor, %{}),
      idle_elapsed_ms: elapsed_ms,
      stale_cleanup_timeout_ms: state.stream_stale_cleanup_timeout_ms,
      stream_subscription_cleanup_timeout_ms: state.stream_subscription_cleanup_timeout_ms,
      last_activity_monotonic_ms: state.stream_last_activity_monotonic_ms,
      cleanup_started_monotonic_ms: now_ms,
      released_resources: released_resources
    }
  end

  defp operation_timeout_event(state, now_ms, elapsed_ms, released_resources) do
    %{
      cleanup_reason: :operation_timeout,
      stream_kind: state.stream_kind,
      runtime_source: Map.get(state, :runtime_source),
      transport: Map.get(state, :transport),
      parent_call_id: Map.get(state, :parent_call_id),
      child_id: Map.get(state, :child_id),
      session_id: Map.get(state, :session_id),
      external_ids: Map.get(state, :external_ids, %{}),
      stream_cursor: Map.get(state, :stream_cursor, %{}),
      operation_id: state.stream_active_operation_id,
      operation_elapsed_ms: elapsed_ms,
      operation_timeout_ms:
        state.stream_active_operation_timeout_ms || state.stream_operation_timeout_ms,
      stale_cleanup_timeout_ms: state.stream_stale_cleanup_timeout_ms,
      stream_subscription_cleanup_timeout_ms: state.stream_subscription_cleanup_timeout_ms,
      last_activity_monotonic_ms: state.stream_last_activity_monotonic_ms,
      operation_started_monotonic_ms: state.stream_operation_started_monotonic_ms,
      cleanup_started_monotonic_ms: now_ms,
      released_resources: released_resources
    }
  end

  defp release_registered_resources(state) do
    process_handle_count = length(state.stream_process_handles)
    subscription_count = length(state.stream_subscriptions)
    registered_buffer_count = length(state.stream_registered_buffers)

    Enum.each(state.stream_process_handles, &release_process_handle/1)
    Enum.each(state.stream_subscriptions, &release_subscription/1)
    ets_entry_count = release_registered_buffers(state.stream_registered_buffers)

    {state, pending_event_count} = Mailbox.release_buffers(state)

    released_resources = %{
      process_handles: process_handle_count,
      subscriptions: subscription_count,
      registered_buffers: registered_buffer_count,
      ets_entries: ets_entry_count,
      pending_events: pending_event_count
    }

    state =
      state
      |> Map.put(:stream_process_handles, [])
      |> Map.put(:stream_subscriptions, [])
      |> Map.put(:stream_registered_buffers, [])

    {state, released_resources}
  end

  defp release_process_handle(port) when is_port(port) do
    if Port.info(port) do
      Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp release_process_handle(_resource), do: :ok

  defp release_subscription(fun) when is_function(fun, 0) do
    fun.()
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp release_subscription(fun) when is_function(fun, 1) do
    fun.(:unsubscribe)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp release_subscription({:unsubscribe, pid, message}) when is_pid(pid) do
    send(pid, message)
    :ok
  end

  defp release_subscription({:timer, timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp release_subscription({:monitor, monitor_ref}) when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  defp release_subscription(pid) when is_pid(pid) do
    send(pid, {:unsubscribe, self()})
    :ok
  end

  defp release_subscription(_resource), do: :ok

  defp release_registered_buffers(buffers) do
    Enum.reduce(buffers, 0, fn buffer, acc ->
      acc + release_registered_buffer(buffer)
    end)
  end

  defp release_registered_buffer({:ets, table}), do: release_ets_entries(table)
  defp release_registered_buffer({:ets_table, table}), do: release_ets_entries(table)
  defp release_registered_buffer(%{ets_table: table}), do: release_ets_entries(table)
  defp release_registered_buffer(_buffer), do: 0

  defp release_ets_entries(table) do
    case :ets.info(table, :size) do
      size when is_integer(size) ->
        :ets.delete_all_objects(table)
        size

      :undefined ->
        0
    end
  rescue
    ArgumentError -> 0
  end

  defp route_operation_timeout(%{stream_operation_timeout_target: pid}, cleanup)
       when is_pid(pid) do
    send(pid, {:stream_operation_timeout, cleanup})
  end

  defp route_operation_timeout(_state, _cleanup), do: :ok

  defp maybe_route_timeout_termination(%{stream_cleanup_action: :stop} = state, cleanup) do
    route_lifecycle(state, timeout_termination_event(cleanup))
  end

  defp maybe_route_timeout_termination(_state, _cleanup), do: :ok

  defp timeout_termination_event(cleanup) do
    cleanup
    |> Map.put(:lifecycle_type, :stream_terminated)
    |> Map.put(:exit_state, :normal)
    |> Map.put(:exit_reason, Map.fetch!(cleanup, :cleanup_reason))
  end

  defp route_lifecycle(%{stream_lifecycle_target: pid}, event) when is_pid(pid) do
    send(pid, {:stream_lifecycle_event, event})
  end

  defp route_lifecycle(%{stream_lifecycle_target: fun}, event) when is_function(fun, 1) do
    fun.(event)
  end

  defp route_lifecycle(_state, _event), do: :ok

  defp route_cleanup(%{stream_cleanup_target: pid}, cleanup) when is_pid(pid) do
    send(pid, {:stream_stale_cleanup, cleanup})
  end

  defp route_cleanup(_state, _cleanup), do: :ok

  defp cancel_idle_timer(%{stream_idle_timer_ref: nil} = state), do: state

  defp cancel_idle_timer(%{stream_idle_timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    state
  end

  defp cancel_operation_timer(%{stream_operation_timer_ref: nil} = state), do: state

  defp cancel_operation_timer(%{stream_operation_timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    state
  end

  defp schedule_idle_timeout(timeout_ms, last_activity_ms) do
    Process.send_after(self(), {:stream_idle_timeout, last_activity_ms}, timeout_ms)
  end

  defp schedule_operation_timeout(timeout_ms, operation_id, deadline_ms) do
    Process.send_after(self(), {:stream_operation_timeout, operation_id, deadline_ms}, timeout_ms)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
