defmodule Ourocode.Runtime.Stream.Session do
  @moduledoc """
  OTP process boundary for one runtime session stream.

  Session streams isolate runtime session mappings from child pane streams and
  transport processes while keeping resumable cursor state local to Elixir.
  """

  use GenServer
  alias Ourocode.Runtime.SessionSettings
  alias Ourocode.Runtime.Stream.Lifecycle
  alias Ourocode.Runtime.Stream.Mailbox
  alias Ourocode.Runtime.Stream.Telemetry

  @settings_key_aliases %{
    "external-ids" => :external_ids,
    "external_ids" => :external_ids,
    "operation-timeout-ms" => :operation_timeout_ms,
    "operation_timeout_ms" => :operation_timeout_ms,
    "stale-cleanup-timeout-ms" => :stale_cleanup_timeout_ms,
    "stale_cleanup_timeout_ms" => :stale_cleanup_timeout_ms,
    "stream-cleanup-action" => :stream_cleanup_action,
    "stream_cleanup_action" => :stream_cleanup_action,
    "stream-cursor" => :stream_cursor,
    "stream_cursor" => :stream_cursor,
    "stream-mailbox-backpressure-behavior" => :stream_mailbox_backpressure_behavior,
    "stream_mailbox_backpressure_behavior" => :stream_mailbox_backpressure_behavior,
    "stream-mailbox-backpressure-delay-ms" => :stream_mailbox_backpressure_delay_ms,
    "stream_mailbox_backpressure_delay_ms" => :stream_mailbox_backpressure_delay_ms,
    "stream-mailbox-backpressure-threshold" => :stream_mailbox_backpressure_threshold,
    "stream_mailbox_backpressure_threshold" => :stream_mailbox_backpressure_threshold,
    "stream-mailbox-capacity" => :stream_mailbox_capacity,
    "stream_mailbox_capacity" => :stream_mailbox_capacity,
    "stream-mailbox-drain-interval-ms" => :stream_mailbox_drain_interval_ms,
    "stream_mailbox_drain_interval_ms" => :stream_mailbox_drain_interval_ms,
    "stream-mailbox-overflow-path" => :stream_mailbox_overflow_path,
    "stream_mailbox_overflow_path" => :stream_mailbox_overflow_path,
    "stream-subscription-cleanup-timeout-ms" => :stream_subscription_cleanup_timeout_ms,
    "stream_subscription_cleanup_timeout_ms" => :stream_subscription_cleanup_timeout_ms
  }

  @type state :: %{
          required(:stream_kind) => :session,
          required(:runtime_source) => String.t(),
          required(:session_id) => String.t(),
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

  @spec apply_settings(GenServer.server(), map() | keyword()) ::
          {:ok, state()} | {:error, term()}
  def apply_settings(server, settings) when is_map(settings) or is_list(settings) do
    GenServer.call(server, {:apply_settings, settings})
  end

  @spec snapshot(GenServer.server()) :: state()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    case SessionSettings.normalize(opts) do
      {:ok, opts} ->
        state =
          %{
            stream_kind: :session,
            runtime_source: Keyword.fetch!(opts, :runtime_source),
            session_id: Keyword.get(opts, :session_id, external_session_id(opts)),
            external_ids: Keyword.fetch!(opts, :external_ids),
            stream_cursor: Keyword.fetch!(opts, :stream_cursor),
            transport: Keyword.get(opts, :transport),
            event_count: 0
          }
          |> Map.merge(Mailbox.fields(opts))
          |> Map.merge(Lifecycle.fields(opts))

        Telemetry.emit_start(state)

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
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
      {:ok, state} -> {:reply, :ok, state}
      {{:error, reason}, state} -> {:reply, {:error, reason}, state}
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
  def handle_call({:apply_settings, settings}, _from, state) do
    with {:ok, patch} <- normalize_settings_patch(settings),
         {:ok, normalized} <- SessionSettings.normalize(Map.merge(settings_base(state), patch)) do
      state = apply_normalized_settings(state, normalized)
      {:reply, {:ok, state}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
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
    |> Map.put(:runtime_source, Map.get(event, :runtime_source, state.runtime_source))
    |> Map.put(:session_id, session_id_from_event(event, state.session_id))
    |> maybe_put(:event_seq, Map.get(event, :event_seq))
  end

  defp session_id_from_event(event, fallback) do
    event
    |> Map.get(:external_ids, %{})
    |> Map.get("session_id", fallback)
  end

  defp external_session_id(opts) do
    opts
    |> Keyword.get(:external_ids, %{})
    |> Map.get("session_id", new_id("session"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_settings_patch(settings) when is_list(settings) do
    if Keyword.keyword?(settings) do
      settings |> Map.new() |> normalize_settings_patch()
    else
      {:error, {:invalid_session_settings, "session settings must be a map or keyword list"}}
    end
  end

  defp normalize_settings_patch(settings) when is_map(settings) do
    {:ok, Map.new(settings, fn {key, value} -> {settings_key(key), value} end)}
  end

  defp settings_key(key) when is_atom(key), do: key

  defp settings_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.replace("-", "_")
    |> then(&Map.get(@settings_key_aliases, &1, &1))
  end

  defp settings_key(key), do: key

  defp settings_base(state) do
    %{
      runtime_source: state.runtime_source,
      session_id: state.session_id,
      transport: Map.get(state, :transport),
      external_ids: state.external_ids,
      stream_cursor: state.stream_cursor,
      stream_mailbox_capacity: state.stream_mailbox_capacity,
      stream_mailbox_overflow_path: state.stream_mailbox_overflow_path,
      stream_mailbox_backpressure_threshold: state.stream_mailbox_backpressure_threshold,
      stream_mailbox_backpressure_behavior: state.stream_mailbox_backpressure_behavior,
      stream_mailbox_backpressure_delay_ms: state.stream_mailbox_backpressure_delay_ms,
      stale_cleanup_timeout_ms: state.stream_stale_cleanup_timeout_ms,
      operation_timeout_ms: state.stream_operation_timeout_ms,
      stream_subscription_cleanup_timeout_ms: state.stream_subscription_cleanup_timeout_ms,
      stream_mailbox_drain_interval_ms: state.stream_mailbox_drain_interval_ms,
      stream_cleanup_action: state.stream_cleanup_action
    }
  end

  defp apply_normalized_settings(state, normalized) do
    state
    |> Map.put(:external_ids, Keyword.fetch!(normalized, :external_ids))
    |> Map.put(:stream_cursor, Keyword.fetch!(normalized, :stream_cursor))
    |> Map.put(:stream_mailbox_capacity, Keyword.fetch!(normalized, :stream_mailbox_capacity))
    |> Map.put(
      :stream_mailbox_overflow_path,
      Keyword.fetch!(normalized, :stream_mailbox_overflow_path)
    )
    |> Map.put(
      :stream_mailbox_backpressure_threshold,
      Keyword.fetch!(normalized, :stream_mailbox_backpressure_threshold)
    )
    |> Map.put(
      :stream_mailbox_backpressure_behavior,
      Keyword.fetch!(normalized, :stream_mailbox_backpressure_behavior)
    )
    |> Map.put(
      :stream_mailbox_backpressure_delay_ms,
      Keyword.fetch!(normalized, :stream_mailbox_backpressure_delay_ms)
    )
    |> Map.put(
      :stream_stale_cleanup_timeout_ms,
      Keyword.fetch!(normalized, :stale_cleanup_timeout_ms)
    )
    |> Map.put(:stream_operation_timeout_ms, Keyword.fetch!(normalized, :operation_timeout_ms))
    |> Map.put(
      :stream_subscription_cleanup_timeout_ms,
      Keyword.fetch!(normalized, :stream_subscription_cleanup_timeout_ms)
    )
    |> Map.put(
      :stream_mailbox_drain_interval_ms,
      Keyword.fetch!(normalized, :stream_mailbox_drain_interval_ms)
    )
    |> Map.put(:stream_cleanup_action, Keyword.fetch!(normalized, :stream_cleanup_action))
  end

  defp default_child_id(opts) do
    {__MODULE__, Keyword.get(opts, :runtime_source, "synthetic"), Keyword.get(opts, :session_id)}
  end

  defp new_id(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
