defmodule Ourocode.MCP.Transport.Stdio do
  @moduledoc """
  stdio MCP transport for executing parent JSON-RPC calls.

  The transport owns one external process port, correlates request IDs to
  callers, and emits journal-ready events for parent call lifecycle updates.
  """

  use GenServer

  alias Ourocode.Config
  alias Ourocode.Journal
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.RuntimeEventParser
  alias Ourocode.MCP.Transport.Stdio.LifecycleNormalizer

  @type event :: LifecycleEvent.t()

  @default_timeout 5_000

  defstruct [
    :port,
    :event_sink,
    :parent_call_id,
    :runtime_source,
    :external_ids,
    :journal_path,
    :codec,
    :cleanup_timeout_ms,
    :cleanup_timer_ref,
    :last_activity_monotonic_ms,
    event_seq: 0,
    request_seq: 0,
    pending: %{}
  ]

  @doc """
  Starts a stdio transport process.

  Required options:
    * `:command` - executable path

  Useful options:
    * `:args` - executable args
    * `:event_sink` - pid or one-arity function that receives typed lifecycle events
    * `:parent_call_id` - local parent call mapping ID
    * `:runtime_source` - external runtime source name
    * `:external_ids` - trusted runtime IDs/status map
    * `:journal_path` - JSONL local journal path for persisted lifecycle events
    * `:codec` - module implementing `encode!/1` and `decode/1`
    * `:stale_cleanup_timeout_ms` - idle timeout before closing the owned Port
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Executes a parent MCP JSON-RPC call over stdio and returns its result.
  """
  def call_parent(server, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(server, {:call_parent, method, params, opts}, timeout + 1_000)
  end

  @doc """
  Returns transport-owned runtime metadata useful for supervision and cleanup
  assertions without making callers inspect GenServer internals.
  """
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    cleanup_timeout_ms = cleanup_timeout_ms(opts)
    now_ms = monotonic_ms()

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        {:args, args},
        {:line, 65_536}
      ])

    state = %__MODULE__{
      port: port,
      event_sink: Keyword.get(opts, :event_sink, self()),
      parent_call_id: Keyword.get(opts, :parent_call_id, new_id("parent")),
      runtime_source: Keyword.get(opts, :runtime_source, "synthetic"),
      external_ids: Keyword.get(opts, :external_ids, %{}),
      journal_path: Keyword.get(opts, :journal_path),
      codec: Keyword.get(opts, :codec, Ourocode.Json),
      cleanup_timeout_ms: cleanup_timeout_ms,
      cleanup_timer_ref: schedule_cleanup(cleanup_timeout_ms, now_ms),
      last_activity_monotonic_ms: now_ms
    }

    {:ok, emit(state, :transport_started, %{})}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       transport: :stdio,
       parent_call_id: state.parent_call_id,
       runtime_source: state.runtime_source,
       external_ids: state.external_ids,
       event_seq: state.event_seq,
       request_seq: state.request_seq,
       pending_request_count: map_size(state.pending),
       port: state.port,
       port_open?: port_open?(state.port),
       cleanup_timeout_ms: state.cleanup_timeout_ms,
       last_activity_monotonic_ms: state.last_activity_monotonic_ms
     }, state}
  end

  @impl true
  def handle_call({:call_parent, method, params, opts}, from, state) do
    request_id = next_request_id(state)
    request = %{"jsonrpc" => "2.0", "id" => request_id, "method" => method, "params" => params}
    outbound_raw_context = raw_event_context(state, :outbound, request)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    state = touch(state)

    case write_request(state, request) do
      :ok ->
        timer = Process.send_after(self(), {:request_timeout, request_id}, timeout)
        external_ids = event_external_ids(state, request)

        pending = %{
          from: from,
          method: method,
          params: params,
          external_ids: external_ids,
          timer: timer,
          started_at_ms: now_ms()
        }

        state =
          state
          |> Map.update!(:request_seq, &(&1 + 1))
          |> Map.update!(:pending, &Map.put(&1, request_id, pending))
          |> emit(:parent_call_started, %{
            external_ids: external_ids,
            request_id: request_id,
            method: method,
            params: params,
            raw_event: annotate_raw_event(request, outbound_raw_context)
          })

        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason},
         emit(state, :parent_call_write_failed, %{
           external_ids: event_external_ids(state, request),
           error: reason,
           raw_event: annotate_raw_event(request, outbound_raw_context)
         })}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    {:noreply, state |> touch() |> handle_line(line)}
  end

  def handle_info({port, {:data, {:noeol, line}}}, %{port: port} = state) do
    {:noreply, state |> touch() |> handle_line(line)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = {:port_exit, status}

    state =
      state.pending
      |> Enum.reduce(state, fn {request_id, pending}, acc ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, {:error, reason})

        emit(acc, :parent_call_failed, %{
          external_ids: pending.external_ids,
          request_id: request_id,
          error: reason
        })
      end)
      |> Map.put(:pending, %{})
      |> emit(:transport_exited, %{error: reason})

    {:stop, reason, state}
  end

  def handle_info({:request_timeout, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        {:noreply, state}

      {pending, pending_map} ->
        error = {:timeout, request_id}
        GenServer.reply(pending.from, {:error, error})

        state =
          state
          |> Map.put(:pending, pending_map)
          |> emit(:parent_call_failed, %{
            external_ids: pending.external_ids,
            request_id: request_id,
            error: error
          })

        {:noreply, state}
    end
  end

  def handle_info({:stdio_cleanup_timeout, last_activity_ms}, state) do
    if last_activity_ms == state.last_activity_monotonic_ms do
      state =
        state
        |> fail_pending({:cleanup_timeout, state.cleanup_timeout_ms})
        |> close_owned_port()
        |> emit(:transport_cleanup, %{
          cleanup_reason: :idle_timeout,
          stale_cleanup_timeout_ms: state.cleanup_timeout_ms,
          released_resources: %{ports: 1}
        })

      {:stop, :normal, %{state | cleanup_timer_ref: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    close_port(port)
    :ok
  end

  defp handle_line(state, line) do
    raw_context = raw_event_context(state, :inbound, String.trim(line))

    case Ourocode.MCP.Transport.StdoutJsonlParser.parse_protocol_line_detailed(
           line,
           state.codec
         ) do
      {:ok, raw_message} ->
        route_raw_protocol_message(state, raw_message, raw_context)

      {:error, %{line: malformed_line, reason: reason}} ->
        emit(state, :transport_decode_failed, %{
          error: {:malformed_stdout_line, reason},
          error_details: %{reason: reason},
          raw_event: annotate_raw_event(%{line: malformed_line}, raw_context)
        })

      :ignore ->
        state
    end
  end

  defp route_raw_protocol_message(state, %{kind: kind} = raw_message, raw_context)
       when kind in [:request, :notification, :unknown] do
    emit_normalized(
      state,
      raw_message
      |> LifecycleNormalizer.normalize_protocol_message(event_context(state))
      |> annotate_event_raw_event(raw_context)
    )
  end

  defp route_raw_protocol_message(state, %{kind: kind, raw: decoded, id: request_id}, raw_context)
       when kind in [:response, :error_response] do
    complete_request(state, to_string(request_id), decoded, raw_context)
  end

  defp complete_request(state, request_id, decoded, raw_context) do
    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        emit(state, :parent_call_unmatched_result, %{
          external_ids: event_external_ids(state, decoded),
          request_id: request_id,
          result: decoded,
          raw_event: annotate_raw_event(decoded, raw_context)
        })

      {pending, pending_map} ->
        Process.cancel_timer(pending.timer)

        reply =
          cond do
            Map.has_key?(decoded, "result") -> {:ok, Map.fetch!(decoded, "result")}
            Map.has_key?(decoded, "error") -> {:error, Map.fetch!(decoded, "error")}
            true -> {:error, {:invalid_response, decoded}}
          end

        GenServer.reply(pending.from, reply)

        response_attrs =
          case reply do
            {:ok, _result} ->
              %{
                request_id: request_id,
                method: pending.method,
                params: pending.params
              }

            {:error, _error} ->
              %{
                request_id: request_id,
                method: pending.method,
                params: pending.params
              }
          end

        response_context =
          state
          |> event_context()
          |> Map.put(:external_ids, event_external_ids(state, decoded, pending.external_ids))

        state
        |> Map.put(:pending, pending_map)
        |> emit_normalized(
          LifecycleNormalizer.parent_call_response(
            decoded,
            reply,
            response_context,
            response_attrs
          )
          |> annotate_event_raw_event(raw_context)
        )
    end
  end

  defp write_request(state, request) do
    payload = state.codec.encode!(request)

    if Port.command(state.port, [payload, "\n"]) do
      :ok
    else
      {:error, :closed}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp fail_pending(state, reason) do
    state.pending
    |> Enum.each(fn {_request_id, pending} ->
      Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, {:error, reason})
    end)

    %{state | pending: %{}}
  end

  defp event_external_ids(state, payload) do
    Map.merge(state.external_ids, RuntimeEventParser.extract_external_ids(payload))
  end

  defp event_external_ids(state, payload, inherited_external_ids) do
    state.external_ids
    |> Map.merge(inherited_external_ids || %{})
    |> Map.merge(RuntimeEventParser.extract_external_ids(payload))
  end

  defp emit(state, type, payload) do
    payload = Map.new(payload)
    external_ids = Map.get(payload, :external_ids, state.external_ids)

    event_attrs =
      payload
      |> Map.merge(%{
        event_seq: state.event_seq + 1,
        type: type,
        transport: :stdio,
        parent_call_id: state.parent_call_id,
        runtime_source: state.runtime_source,
        external_ids: external_ids,
        occurred_at_ms: now_ms()
      })

    event = LifecycleEvent.new(type, event_attrs)

    persist(state.journal_path, event)
    deliver(state.event_sink, event)
    %{state | event_seq: event.event_seq}
  end

  defp emit_normalized(state, %LifecycleEvent{} = event) do
    persist(state.journal_path, event)
    deliver(state.event_sink, event)
    %{state | event_seq: event.event_seq}
  end

  defp annotate_event_raw_event(%LifecycleEvent{raw_event: raw_event} = event, raw_context)
       when is_map(raw_event) do
    %{event | raw_event: annotate_raw_event(raw_event, raw_context)}
  end

  defp annotate_event_raw_event(%LifecycleEvent{} = event, _raw_context), do: event

  defp annotate_raw_event(%{} = raw_event, raw_context) when is_map(raw_context) do
    Map.merge(raw_event, raw_context)
  end

  defp raw_event_context(state, stream_direction, raw_payload) do
    timestamp_ms = now_ms()

    %{
      transport: :stdio,
      transport_type: :stdio,
      process_identifier: process_identifier(state),
      session_identifier: session_identifier(state),
      stream_direction: stream_direction,
      timestamp_ms: timestamp_ms,
      raw_payload_ref: raw_payload_ref(raw_payload)
    }
  end

  defp process_identifier(state) do
    %{
      port: inspect(state.port),
      os_pid: port_os_pid(state.port)
    }
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp session_identifier(state) do
    state.external_ids["session_id"] ||
      state.external_ids[:session_id] ||
      state.external_ids["native_session_id"] ||
      state.external_ids[:native_session_id] ||
      state.parent_call_id
  end

  defp raw_payload_ref(payload) when is_binary(payload) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

  defp raw_payload_ref(payload) do
    "sha256:" <>
      Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(payload)), case: :lower)
  end

  defp event_context(state) do
    %{
      event_seq: state.event_seq + 1,
      parent_call_id: state.parent_call_id,
      runtime_source: state.runtime_source,
      external_ids: state.external_ids,
      occurred_at_ms: now_ms()
    }
  end

  defp persist(nil, _event), do: :ok

  defp persist(path, event) when is_binary(path) do
    Journal.append!(path, canonical_journal_event(event))
  end

  defp canonical_journal_event(%LifecycleEvent{} = event) do
    event
    |> Map.from_struct()
    |> canonical_journal_event()
  end

  defp canonical_journal_event(%{} = event) do
    event
    |> canonicalize_journal_notification()
    |> canonicalize_journal_decode_error()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp canonicalize_journal_notification(%{notification: notification} = event)
       when is_map(notification) do
    Map.put(
      event,
      :notification,
      Map.take(notification, ["id", "method", "params", :id, :method, :params])
    )
  end

  defp canonicalize_journal_notification(event), do: event

  defp canonicalize_journal_decode_error(
         %{type: :transport_decode_failed, error: {:malformed_stdout_line, reason}} = event
       ) do
    reason_code = decode_reason_code(reason)

    event
    |> Map.put(:error, {:malformed_stdout_line, reason_code})
    |> Map.put(:error_details, %{reason: reason_code})
  end

  defp canonicalize_journal_decode_error(event), do: event

  defp decode_reason_code({reason, _raw_fragment}), do: reason
  defp decode_reason_code([reason, _raw_fragment]), do: reason
  defp decode_reason_code(reason), do: reason

  defp deliver(pid, event) when is_pid(pid), do: send(pid, {:ourocode_event, event})
  defp deliver(fun, event) when is_function(fun, 1), do: fun.(event)
  defp deliver(_sink, _event), do: :ok

  defp next_request_id(state), do: Integer.to_string(state.request_seq + 1)

  defp touch(state) do
    now_ms = monotonic_ms()

    state
    |> cancel_cleanup_timer()
    |> Map.put(:last_activity_monotonic_ms, now_ms)
    |> Map.put(:cleanup_timer_ref, schedule_cleanup(state.cleanup_timeout_ms, now_ms))
  end

  defp cleanup_timeout_ms(opts) do
    Keyword.get(opts, :stale_cleanup_timeout_ms, Config.defaults().stale_cleanup_timeout_ms)
  end

  defp schedule_cleanup(:infinity, _last_activity_ms), do: nil

  defp schedule_cleanup(timeout_ms, last_activity_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    Process.send_after(self(), {:stdio_cleanup_timeout, last_activity_ms}, timeout_ms)
  end

  defp cancel_cleanup_timer(%{cleanup_timer_ref: nil} = state), do: state

  defp cancel_cleanup_timer(%{cleanup_timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    state
  end

  defp close_owned_port(state) do
    close_port(state.port)
    state
  end

  defp new_id(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp port_open?(port) do
    !!Port.info(port)
  rescue
    ArgumentError -> false
  end

  defp close_port(port) do
    if Port.info(port) do
      Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp now_ms, do: System.system_time(:millisecond)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
