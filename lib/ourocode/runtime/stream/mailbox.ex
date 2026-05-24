defmodule Ourocode.Runtime.Stream.Mailbox do
  @moduledoc """
  Bounded logical event mailbox for runtime stream processes.

  The BEAM process mailbox remains an implementation detail. Stream processes
  accept events into this bounded queue first so overflow behavior is explicit,
  configurable, testable, and recoverable through stream snapshots.
  """

  alias Ourocode.Runtime.Stream.MailboxDrain
  alias Ourocode.Runtime.Stream.MailboxFlush
  alias Ourocode.Runtime.Stream.MailboxPressure
  alias Ourocode.Runtime.Stream.MailboxRouting
  alias Ourocode.Runtime.Stream.MailboxState
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
    MailboxState.fields(opts)
  end

  @spec enqueue(map(), map()) :: {:ok, map()} | {{:error, overflow()}, map()}
  def enqueue(state, event) when is_map(event) do
    if state.stream_mailbox_pending_count < state.stream_mailbox_capacity do
      state =
        state
        |> apply_backpressure(event)
        |> Map.update!(:stream_mailbox_pending, &:queue.in(event, &1))
        |> Map.update!(:stream_mailbox_pending_count, &(&1 + 1))
        |> MailboxDrain.schedule()

      {:ok, state}
    else
      overflow = MailboxPressure.overflow(state, event)

      MailboxRouting.route_overflow(state, overflow)

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
          |> MailboxRouting.route_buffered_event(event)

        MailboxDrain.schedule(state)

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
      |> MailboxFlush.mark_completed(reason)
      |> maybe_relieve_released_backpressure(pending_count)

    flush = MailboxFlush.payload(state, reason, pending_count, rendered_event_seqs)

    MailboxRouting.route_final_flush(state, flush)

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

  defp drain_all_pending(state, apply_event, rendered_event_seqs) do
    case :queue.out(state.stream_mailbox_pending) do
      {{:value, event}, queue} ->
        state =
          state
          |> Map.put(:stream_mailbox_pending, queue)
          |> Map.update!(:stream_mailbox_pending_count, &(&1 - 1))
          |> then(fn state -> apply_event.(state, event) end)
          |> MailboxRouting.route_buffered_event(event)

        MailboxRouting.route_rendered_event(state, event)

        drain_all_pending(state, apply_event, [Map.get(event, :event_seq) | rendered_event_seqs])

      {:empty, _queue} ->
        {state, rendered_event_seqs}
    end
  end

  defp apply_backpressure(state, event) do
    if MailboxPressure.backpressure?(state) do
      pressure = MailboxPressure.backpressure(state, event)

      MailboxRouting.route_backpressure(state, pressure)
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
      pressure = MailboxPressure.relief(state, event, previous_pending_count)

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
    pressure = MailboxPressure.release_relief(state, pending_count)

    Telemetry.emit_backpressure_relieved(state, pressure)
    Map.put(state, :stream_mailbox_backpressure_active?, false)
  end

  defp maybe_relieve_released_backpressure(state, _pending_count), do: state

  defp delay_backpressure(%{stream_mailbox_backpressure_behavior: :delay} = state, pressure) do
    if pressure.delay_ms > 0, do: Process.sleep(pressure.delay_ms)
    state
  end

  defp delay_backpressure(state, _pressure), do: state
end
