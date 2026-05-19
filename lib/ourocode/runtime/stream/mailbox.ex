defmodule Ourocode.Runtime.Stream.Mailbox do
  @moduledoc """
  Bounded logical event mailbox for runtime stream processes.

  The BEAM process mailbox remains an implementation detail. Stream processes
  accept events into this bounded queue first so overflow behavior is explicit,
  configurable, testable, and recoverable through stream snapshots.
  """

  alias Ourocode.Config
  alias Ourocode.Runtime.Stream.Telemetry

  @type overflow_path :: :drop | :notify
  @type overflow_behavior :: :drop_newest
  @type backpressure_behavior :: :none | :notify | :delay
  @type overflow :: %{
          required(:overflow_path) => overflow_path(),
          required(:overflow_behavior) => overflow_behavior(),
          required(:stream_kind) => atom(),
          required(:event_seq) => term(),
          required(:dropped_event_seq) => term(),
          required(:capacity) => pos_integer(),
          required(:retained_pending_count) => non_neg_integer()
        }
  @type backpressure :: %{
          required(:backpressure_behavior) => backpressure_behavior(),
          required(:stream_kind) => atom(),
          required(:event_seq) => term(),
          required(:threshold) => pos_integer(),
          required(:capacity) => pos_integer(),
          required(:pending_count) => non_neg_integer(),
          required(:delay_ms) => non_neg_integer()
        }
  @type final_flush :: %{
          required(:reason) => atom(),
          required(:stream_kind) => atom(),
          required(:flushed_pending_count) => non_neg_integer(),
          required(:pending_count) => non_neg_integer(),
          required(:stream_cursor) => map()
        }

  @spec fields(keyword()) :: map()
  def fields(opts) when is_list(opts) do
    config = Config.defaults()

    %{
      stream_mailbox_capacity:
        Keyword.get(opts, :stream_mailbox_capacity, config.stream_mailbox_capacity),
      stream_mailbox_overflow_path:
        Keyword.get(opts, :stream_mailbox_overflow_path, config.stream_mailbox_overflow_path),
      stream_mailbox_overflow_target: Keyword.get(opts, :stream_mailbox_overflow_target),
      stream_mailbox_backpressure_threshold:
        Keyword.get(
          opts,
          :stream_mailbox_backpressure_threshold,
          config.stream_mailbox_backpressure_threshold
        ),
      stream_mailbox_backpressure_behavior:
        Keyword.get(
          opts,
          :stream_mailbox_backpressure_behavior,
          config.stream_mailbox_backpressure_behavior
        ),
      stream_mailbox_backpressure_target: Keyword.get(opts, :stream_mailbox_backpressure_target),
      stream_mailbox_backpressure_delay_ms:
        Keyword.get(
          opts,
          :stream_mailbox_backpressure_delay_ms,
          config.stream_mailbox_backpressure_delay_ms
        ),
      stream_mailbox_backpressure_count: 0,
      stream_mailbox_backpressure_active?: false,
      stream_mailbox_final_flush_target: Keyword.get(opts, :stream_mailbox_final_flush_target),
      stream_mailbox_rendered_event_target:
        Keyword.get(opts, :stream_mailbox_rendered_event_target),
      stream_event_subscribers: Keyword.get(opts, :stream_event_subscribers, []),
      stream_mailbox_final_flush_count: 0,
      stream_completion_status: :streaming,
      stream_completion_cursor: nil,
      stream_mailbox_pending: :queue.new(),
      stream_mailbox_pending_count: 0,
      stream_mailbox_overflow_count: 0,
      stream_mailbox_draining?: false,
      stream_mailbox_drain_interval_ms: Keyword.get(opts, :stream_mailbox_drain_interval_ms, 0)
    }
  end

  @spec enqueue(map(), map()) :: {:ok, map()} | {{:error, overflow()}, map()}
  def enqueue(state, event) when is_map(event) do
    if state.stream_mailbox_pending_count < state.stream_mailbox_capacity do
      state =
        state
        |> apply_backpressure(event)
        |> Map.update!(:stream_mailbox_pending, &:queue.in(event, &1))
        |> Map.update!(:stream_mailbox_pending_count, &(&1 + 1))
        |> schedule_drain()

      {:ok, state}
    else
      overflow = %{
        overflow_path: state.stream_mailbox_overflow_path,
        overflow_behavior: :drop_newest,
        stream_kind: state.stream_kind,
        event_seq: Map.get(event, :event_seq),
        dropped_event_seq: Map.get(event, :event_seq),
        capacity: state.stream_mailbox_capacity,
        retained_pending_count: state.stream_mailbox_pending_count
      }

      route_overflow(state, overflow)

      {{:error, overflow}, Map.update!(state, :stream_mailbox_overflow_count, &(&1 + 1))}
    end
  end

  @spec drain_one(map(), (map(), map() -> map())) :: map()
  def drain_one(state, apply_event) when is_function(apply_event, 2) do
    case :queue.out(state.stream_mailbox_pending) do
      {{:value, event}, queue} ->
        previous_pending_count = state.stream_mailbox_pending_count

        state =
          state
          |> Map.put(:stream_mailbox_pending, queue)
          |> Map.update!(:stream_mailbox_pending_count, &(&1 - 1))
          |> Map.put(:stream_mailbox_draining?, false)
          |> maybe_relieve_backpressure(event, previous_pending_count)

        state =
          state
          |> then(fn state -> apply_event.(state, event) end)
          |> route_buffered_event(event)

        schedule_drain(state)

      {:empty, _queue} ->
        Map.put(state, :stream_mailbox_draining?, false)
    end
  end

  @spec final_flush(map(), (map(), map() -> map()), atom()) :: {map(), final_flush()}
  def final_flush(state, apply_event, reason \\ :stream_completed)
      when is_map(state) and is_function(apply_event, 2) and is_atom(reason) do
    pending_count = Map.get(state, :stream_mailbox_pending_count, 0)

    {state, rendered_event_seqs} =
      state
      |> drain_all_pending(apply_event, [])

    state =
      state
      |> Map.put(:stream_mailbox_draining?, false)
      |> Map.update(:stream_mailbox_final_flush_count, 1, &(&1 + 1))
      |> maybe_mark_stream_completed(reason)
      |> maybe_relieve_released_backpressure(pending_count)

    flush = %{
      reason: reason,
      stream_kind: state.stream_kind,
      runtime_source: Map.get(state, :runtime_source),
      transport: Map.get(state, :transport),
      parent_call_id: Map.get(state, :parent_call_id),
      child_id: Map.get(state, :child_id),
      session_id: Map.get(state, :session_id),
      external_ids: Map.get(state, :external_ids, %{}),
      stream_cursor: Map.get(state, :stream_cursor, %{}),
      flushed_pending_count: pending_count,
      rendered_event_seqs: Enum.reverse(rendered_event_seqs),
      pending_count: Map.get(state, :stream_mailbox_pending_count, 0),
      final_flush_count: state.stream_mailbox_final_flush_count,
      completion_status: state.stream_completion_status,
      completion_cursor: state.stream_completion_cursor
    }

    route_final_flush(state, flush)

    {state, flush}
  end

  @spec release_buffers(map()) :: {map(), non_neg_integer()}
  def release_buffers(state) do
    pending_count = Map.get(state, :stream_mailbox_pending_count, 0)

    state =
      state
      |> Map.put(:stream_mailbox_pending, :queue.new())
      |> Map.put(:stream_mailbox_pending_count, 0)
      |> Map.put(:stream_mailbox_draining?, false)
      |> maybe_relieve_released_backpressure(pending_count)

    {state, pending_count}
  end

  defp schedule_drain(%{stream_mailbox_drain_interval_ms: :manual} = state), do: state

  defp schedule_drain(%{stream_mailbox_pending_count: 0} = state) do
    Map.put(state, :stream_mailbox_draining?, false)
  end

  defp schedule_drain(%{stream_mailbox_draining?: true} = state), do: state

  defp schedule_drain(state) do
    Process.send_after(self(), :drain_stream_mailbox, state.stream_mailbox_drain_interval_ms)
    Map.put(state, :stream_mailbox_draining?, true)
  end

  defp drain_all_pending(state, apply_event, rendered_event_seqs) do
    case :queue.out(state.stream_mailbox_pending) do
      {{:value, event}, queue} ->
        state =
          state
          |> Map.put(:stream_mailbox_pending, queue)
          |> Map.update!(:stream_mailbox_pending_count, &(&1 - 1))
          |> then(fn state -> apply_event.(state, event) end)
          |> route_buffered_event(event)

        route_rendered_event(state, event)

        drain_all_pending(state, apply_event, [Map.get(event, :event_seq) | rendered_event_seqs])

      {:empty, _queue} ->
        {state, rendered_event_seqs}
    end
  end

  defp maybe_mark_stream_completed(state, :stream_completed) do
    state
    |> Map.put(:stream_completion_status, :completed)
    |> Map.put(:stream_completion_cursor, Map.get(state, :stream_cursor, %{}))
  end

  defp maybe_mark_stream_completed(state, _reason), do: state

  defp apply_backpressure(state, event) do
    if backpressure?(state) do
      pressure = %{
        backpressure_behavior: state.stream_mailbox_backpressure_behavior,
        stream_kind: state.stream_kind,
        event_seq: Map.get(event, :event_seq),
        threshold: state.stream_mailbox_backpressure_threshold,
        capacity: state.stream_mailbox_capacity,
        pending_count: state.stream_mailbox_pending_count,
        delay_ms: backpressure_delay_ms(state)
      }

      route_backpressure(state, pressure)
      maybe_emit_backpressure_detected(state, pressure)

      state
      |> delay_backpressure(pressure)
      |> Map.update!(:stream_mailbox_backpressure_count, &(&1 + 1))
      |> Map.put(:stream_mailbox_backpressure_active?, true)
    else
      state
    end
  end

  defp maybe_emit_backpressure_detected(
         %{stream_mailbox_backpressure_active?: false} = state,
         pressure
       ) do
    Telemetry.emit_backpressure_detected(state, pressure)
  end

  defp maybe_emit_backpressure_detected(_state, _pressure), do: :ok

  defp maybe_relieve_backpressure(
         %{stream_mailbox_backpressure_active?: true} = state,
         event,
         previous_pending_count
       ) do
    if state.stream_mailbox_pending_count < state.stream_mailbox_backpressure_threshold do
      pressure = %{
        backpressure_behavior: state.stream_mailbox_backpressure_behavior,
        stream_kind: state.stream_kind,
        event_seq: Map.get(event, :event_seq),
        threshold: state.stream_mailbox_backpressure_threshold,
        capacity: state.stream_mailbox_capacity,
        pending_count: state.stream_mailbox_pending_count,
        previous_pending_count: previous_pending_count,
        delay_ms: 0
      }

      Telemetry.emit_backpressure_relieved(state, pressure)
      Map.put(state, :stream_mailbox_backpressure_active?, false)
    else
      state
    end
  end

  defp maybe_relieve_backpressure(state, _event, _previous_pending_count), do: state

  defp maybe_relieve_released_backpressure(
         %{stream_mailbox_backpressure_active?: true} = state,
         pending_count
       )
       when pending_count > 0 do
    pressure = %{
      backpressure_behavior: state.stream_mailbox_backpressure_behavior,
      stream_kind: state.stream_kind,
      event_seq: Map.get(state.stream_cursor, :event_seq),
      threshold: state.stream_mailbox_backpressure_threshold,
      capacity: state.stream_mailbox_capacity,
      pending_count: 0,
      previous_pending_count: pending_count,
      delay_ms: 0
    }

    Telemetry.emit_backpressure_relieved(state, pressure)
    Map.put(state, :stream_mailbox_backpressure_active?, false)
  end

  defp maybe_relieve_released_backpressure(state, _pending_count), do: state

  defp backpressure?(%{stream_mailbox_backpressure_behavior: :none}), do: false

  defp backpressure?(state) do
    state.stream_mailbox_pending_count >= state.stream_mailbox_backpressure_threshold
  end

  defp delay_backpressure(%{stream_mailbox_backpressure_behavior: :delay} = state, pressure) do
    if pressure.delay_ms > 0, do: Process.sleep(pressure.delay_ms)
    state
  end

  defp delay_backpressure(state, _pressure), do: state

  defp backpressure_delay_ms(%{stream_mailbox_backpressure_behavior: :delay} = state) do
    state.stream_mailbox_backpressure_delay_ms
  end

  defp backpressure_delay_ms(_state), do: 0

  defp route_backpressure(
         %{
           stream_mailbox_backpressure_behavior: behavior,
           stream_mailbox_backpressure_target: pid
         },
         pressure
       )
       when behavior in [:notify, :delay] and is_pid(pid) do
    send(pid, {:stream_mailbox_backpressure, pressure})
  end

  defp route_backpressure(_state, _pressure), do: :ok

  defp route_overflow(
         %{stream_mailbox_overflow_path: :notify, stream_mailbox_overflow_target: pid},
         overflow
       )
       when is_pid(pid) do
    send(pid, {:stream_mailbox_overflow, overflow})
  end

  defp route_overflow(_state, _overflow), do: :ok

  defp route_final_flush(%{stream_mailbox_final_flush_target: pid}, flush) when is_pid(pid) do
    send(pid, {:stream_mailbox_final_flush, flush})
  end

  defp route_final_flush(_state, _flush), do: :ok

  defp route_rendered_event(%{stream_mailbox_rendered_event_target: pid}, event)
       when is_pid(pid) do
    send(pid, {:stream_mailbox_rendered_event, event})
  end

  defp route_rendered_event(_state, _event), do: :ok

  defp route_buffered_event(state, event) do
    Enum.each(Map.get(state, :stream_event_subscribers, []), fn
      pid when is_pid(pid) ->
        send(pid, {:stream_event, event})

      {pid, tag} when is_pid(pid) ->
        send(pid, {tag, event})

      {pid, tag, metadata} when is_pid(pid) and is_map(metadata) ->
        send(pid, {tag, Map.merge(metadata, event)})

      _unsupported ->
        :ok
    end)

    state
  end
end
