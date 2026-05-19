defmodule Ourocode.Runtime.Stream.Child do
  @moduledoc """
  OTP process boundary for one child agent/session event stream.

  Child streams are supervised independently so a crashing child pane stream can
  be cleaned up without taking down the parent call or transport stream.
  """

  use GenServer
  alias Ourocode.Runtime.Stream.Lifecycle
  alias Ourocode.Runtime.Stream.Mailbox
  alias Ourocode.Runtime.Stream.Telemetry

  @type state :: %{
          required(:stream_kind) => :child,
          required(:child_id) => String.t(),
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:transport) => atom() | nil,
          required(:external_ids) => map(),
          required(:stream_cursor) => map(),
          required(:event_count) => non_neg_integer(),
          required(:stream_mailbox_capacity) => pos_integer(),
          required(:stream_mailbox_pending_count) => non_neg_integer(),
          required(:stream_mailbox_overflow_count) => non_neg_integer(),
          required(:stream_mailbox_backpressure_threshold) => pos_integer(),
          required(:stream_mailbox_backpressure_behavior) => :none | :notify | :delay,
          required(:stream_mailbox_backpressure_delay_ms) => pos_integer(),
          required(:stream_mailbox_backpressure_count) => non_neg_integer(),
          required(:stream_mailbox_backpressure_active?) => boolean(),
          required(:stream_mailbox_final_flush_count) => non_neg_integer(),
          required(:stream_process_handles) => list(),
          required(:stream_subscriptions) => list(),
          required(:stream_event_subscribers) => list(),
          required(:stream_registered_buffers) => list(),
          required(:stream_status) => :active | :stale,
          required(:stream_last_activity_monotonic_ms) => integer(),
          required(:stream_stale_cleanup_timeout_ms) => pos_integer(),
          required(:stream_subscription_cleanup_timeout_ms) => pos_integer(),
          required(:stream_operation_timeout_ms) => pos_integer(),
          required(:stream_active_operation_id) => term() | nil,
          required(:stream_cleanup_reason) => nil | :idle_timeout | :operation_timeout
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :id, default_child_id(opts)),
      start: {__MODULE__, :start_link, [Keyword.delete(opts, :id)]},
      restart: Keyword.get(opts, :restart, :temporary),
      shutdown: Keyword.get(opts, :shutdown, 5_000),
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec record_event(GenServer.server(), map()) :: :ok | {:error, map()}
  def record_event(server, event) when is_map(event) do
    GenServer.call(server, {:record_event, event})
  end

  @spec begin_operation(GenServer.server(), term(), keyword()) :: :ok
  def begin_operation(server, operation_id, opts \\ []) do
    GenServer.call(server, {:begin_operation, operation_id, opts})
  end

  @spec complete_operation(GenServer.server(), term()) :: :ok | {:error, :operation_not_active}
  def complete_operation(server, operation_id) do
    GenServer.call(server, {:complete_operation, operation_id})
  end

  @spec register_resource(GenServer.server(), :process_handle | :subscription | :buffer, term()) ::
          :ok | {:error, :unsupported_resource_kind}
  def register_resource(server, kind, resource) do
    GenServer.call(server, {:register_resource, kind, resource})
  end

  @spec snapshot(GenServer.server()) :: state()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    child_id = Keyword.get(opts, :child_id, new_id("child"))
    parent_call_id = Keyword.get(opts, :parent_call_id, new_id("parent"))

    state =
      %{
        stream_kind: :child,
        child_id: child_id,
        parent_call_id: parent_call_id,
        runtime_source: Keyword.get(opts, :runtime_source, "synthetic"),
        transport: Keyword.get(opts, :transport),
        external_ids: Keyword.get(opts, :external_ids, %{}),
        stream_cursor:
          Keyword.get(opts, :stream_cursor, %{
            child_id: child_id,
            parent_call_id: parent_call_id
          }),
        event_count: 0
      }
      |> Map.merge(Mailbox.fields(opts))
      |> Map.merge(Lifecycle.fields(opts))

    Telemetry.emit_start(state)

    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Telemetry.emit_stop(state, reason)
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = drain_pending_for_snapshot(state)
    {:reply, state, state}
  end

  @impl true
  def handle_call({:record_event, event}, _from, state) do
    case state |> Lifecycle.touch() |> Mailbox.enqueue(event) do
      {:ok, state} -> {:reply, :ok, state}
      {{:error, overflow}, state} -> {:reply, {:error, overflow}, state}
    end
  end

  @impl true
  def handle_call({:begin_operation, operation_id, opts}, _from, state) do
    {:reply, :ok, Lifecycle.begin_operation(state, operation_id, opts)}
  end

  @impl true
  def handle_call({:complete_operation, operation_id}, _from, state) do
    case Lifecycle.complete_operation(state, operation_id) do
      {:ok, state} ->
        {state, _flush} = Mailbox.final_flush(state, &apply_event/2, :stream_completed)
        {:reply, :ok, state}

      {{:error, reason}, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:register_resource, kind, resource}, _from, state) do
    case Lifecycle.register_resource(state, kind, resource) do
      {:ok, state} -> {:reply, :ok, state}
      {{:error, reason}, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:drain_stream_mailbox, state) do
    {:noreply, Mailbox.drain_one(state, &apply_event/2)}
  end

  @impl true
  def handle_info({:stream_idle_timeout, last_activity_ms}, state) do
    Lifecycle.handle_idle_timeout(state, last_activity_ms)
  end

  @impl true
  def handle_info({:stream_operation_timeout, operation_id, deadline_ms}, state) do
    Lifecycle.handle_operation_timeout(state, operation_id, deadline_ms)
  end

  defp apply_event(state, event) do
    state
    |> Map.update!(:event_count, &(&1 + 1))
    |> Map.put(:stream_cursor, next_cursor(state, event))
  end

  defp drain_pending_for_snapshot(%{stream_mailbox_drain_interval_ms: 0} = state) do
    drain_until_empty(state)
  end

  defp drain_pending_for_snapshot(state), do: state

  defp drain_until_empty(%{stream_mailbox_pending_count: 0} = state), do: state

  defp drain_until_empty(state) do
    state
    |> Mailbox.drain_one(&apply_event/2)
    |> drain_until_empty()
  end

  defp next_cursor(state, event) do
    state.stream_cursor
    |> Map.put(:child_id, Map.get(event, :child_id, state.child_id))
    |> Map.put(:parent_call_id, Map.get(event, :parent_call_id, state.parent_call_id))
    |> maybe_put(:transport, Map.get(event, :transport, state.transport))
    |> maybe_put(:event_seq, Map.get(event, :event_seq))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_child_id(opts) do
    {__MODULE__, Keyword.get(opts, :parent_call_id), Keyword.get(opts, :child_id)}
  end

  defp new_id(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
