defmodule Ourocode.Runtime.Stream.Telemetry do
  @moduledoc """
  Telemetry event helpers for supervised runtime stream processes.
  """

  @start_event [:ourocode, :runtime, :stream, :start]
  @stop_event [:ourocode, :runtime, :stream, :stop]
  @crash_event [:ourocode, :runtime, :stream, :crash]
  @cleanup_event [:ourocode, :runtime, :stream, :cleanup]
  @backpressure_detected_event [:ourocode, :runtime, :stream, :backpressure, :detected]
  @backpressure_relieved_event [:ourocode, :runtime, :stream, :backpressure, :relieved]

  @spec start_event() :: [atom()]
  def start_event, do: @start_event

  @spec stop_event() :: [atom()]
  def stop_event, do: @stop_event

  @spec crash_event() :: [atom()]
  def crash_event, do: @crash_event

  @spec cleanup_event() :: [atom()]
  def cleanup_event, do: @cleanup_event

  @spec backpressure_detected_event() :: [atom()]
  def backpressure_detected_event, do: @backpressure_detected_event

  @spec backpressure_relieved_event() :: [atom()]
  def backpressure_relieved_event, do: @backpressure_relieved_event

  @spec emit_start(map()) :: :ok
  def emit_start(state) when is_map(state) do
    execute(
      @start_event,
      %{system_time: System.system_time(), monotonic_time: monotonic_ms()},
      metadata(state)
    )
  end

  @spec emit_stop(map(), term()) :: :ok
  def emit_stop(state, reason) when is_map(state) do
    metadata =
      state
      |> metadata()
      |> Map.put(:exit_reason, reason)
      |> Map.put(:exit_state, exit_state(reason))

    execute(
      @stop_event,
      %{system_time: System.system_time(), monotonic_time: monotonic_ms()},
      metadata
    )

    emit_crash(state, reason, metadata)
  end

  @spec emit_crash(map(), term()) :: :ok
  def emit_crash(state, reason) when is_map(state) do
    state
    |> metadata()
    |> Map.put(:exit_reason, reason)
    |> Map.put(:exit_state, exit_state(reason))
    |> then(&emit_crash(state, reason, &1))
  end

  @spec emit_cleanup(map(), map()) :: :ok
  def emit_cleanup(state, cleanup) when is_map(state) and is_map(cleanup) do
    metadata =
      state
      |> metadata()
      |> Map.merge(cleanup)
      |> Map.put(:cleanup_state, :completed)
      |> Map.put(:stream_status, :stale)
      |> Map.put(:pid, self())

    execute(
      @cleanup_event,
      cleanup_measurements(cleanup),
      metadata
    )
  end

  @spec emit_backpressure_detected(map(), map()) :: :ok
  def emit_backpressure_detected(state, pressure) when is_map(state) and is_map(pressure) do
    emit_backpressure(@backpressure_detected_event, state, pressure, :detected)
  end

  @spec emit_backpressure_relieved(map(), map()) :: :ok
  def emit_backpressure_relieved(state, pressure) when is_map(state) and is_map(pressure) do
    emit_backpressure(@backpressure_relieved_event, state, pressure, :relieved)
  end

  defp execute(event_name, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      :telemetry.execute(event_name, measurements, metadata)
    end

    :ok
  end

  defp emit_crash(_state, _reason, %{exit_state: :normal}), do: :ok

  defp emit_crash(_state, reason, metadata) do
    metadata =
      metadata
      |> Map.put(:crash_reason, reason)
      |> Map.put(:crash_state, :error)

    execute(
      @crash_event,
      %{system_time: System.system_time(), monotonic_time: monotonic_ms()},
      metadata
    )
  end

  defp emit_backpressure(event_name, state, pressure, pressure_state) do
    metadata =
      state
      |> metadata()
      |> Map.merge(pressure)
      |> Map.put(:pressure_state, pressure_state)
      |> Map.put(:queue_depth, Map.get(pressure, :pending_count))
      |> Map.put(:stream_mailbox_pending_count, Map.get(pressure, :pending_count))
      |> Map.put(:stream_mailbox_capacity, Map.get(pressure, :capacity))
      |> Map.put(:stream_mailbox_backpressure_threshold, Map.get(pressure, :threshold))
      |> Map.put(:stream_mailbox_backpressure_behavior, Map.get(pressure, :backpressure_behavior))

    execute(
      event_name,
      %{
        system_time: System.system_time(),
        monotonic_time: monotonic_ms(),
        queue_depth: Map.get(pressure, :pending_count),
        capacity: Map.get(pressure, :capacity),
        threshold: Map.get(pressure, :threshold)
      },
      metadata
    )
  end

  defp cleanup_measurements(cleanup) do
    released_resources = Map.get(cleanup, :released_resources, %{})

    %{
      system_time: System.system_time(),
      monotonic_time: monotonic_ms(),
      idle_elapsed_ms: Map.get(cleanup, :idle_elapsed_ms),
      operation_elapsed_ms: Map.get(cleanup, :operation_elapsed_ms),
      stale_cleanup_timeout_ms: Map.get(cleanup, :stale_cleanup_timeout_ms),
      stream_subscription_cleanup_timeout_ms:
        Map.get(cleanup, :stream_subscription_cleanup_timeout_ms),
      operation_timeout_ms: Map.get(cleanup, :operation_timeout_ms),
      released_process_handles: Map.get(released_resources, :process_handles, 0),
      released_subscriptions: Map.get(released_resources, :subscriptions, 0),
      released_registered_buffers: Map.get(released_resources, :registered_buffers, 0),
      released_ets_entries: Map.get(released_resources, :ets_entries, 0),
      released_pending_events: Map.get(released_resources, :pending_events, 0)
    }
  end

  defp metadata(state) do
    %{
      stream_kind: state.stream_kind,
      runtime_source: Map.get(state, :runtime_source),
      transport: Map.get(state, :transport),
      parent_call_id: Map.get(state, :parent_call_id),
      child_id: Map.get(state, :child_id),
      session_id: Map.get(state, :session_id),
      external_ids: Map.get(state, :external_ids, %{}),
      stream_cursor: Map.get(state, :stream_cursor, %{}),
      event_count: Map.get(state, :event_count, 0),
      stream_status: Map.get(state, :stream_status),
      stream_cleanup_reason: Map.get(state, :stream_cleanup_reason),
      pid: self()
    }
  end

  defp exit_state(:normal), do: :normal
  defp exit_state(:shutdown), do: :normal
  defp exit_state({:shutdown, _reason}), do: :normal
  defp exit_state(_reason), do: :error

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
