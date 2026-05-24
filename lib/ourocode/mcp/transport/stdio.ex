defmodule Ourocode.MCP.Transport.Stdio do
  @moduledoc """
  stdio MCP transport for executing parent JSON-RPC calls.

  The transport owns one external process port, correlates request IDs to
  callers, and emits journal-ready events for parent call lifecycle updates.
  """

  use GenServer

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.Stdio.Cleanup
  alias Ourocode.MCP.Transport.Stdio.EventEmitter
  alias Ourocode.MCP.Transport.Stdio.ParentCall
  alias Ourocode.MCP.Transport.Stdio.PendingRequest
  alias Ourocode.MCP.Transport.Stdio.Snapshot
  alias Ourocode.MCP.Transport.Stdio.State
  alias Ourocode.MCP.Transport.Stdio.StreamProcessor

  @type event :: LifecycleEvent.t()
  @type t :: %__MODULE__{}

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

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        {:args, args},
        {:line, 65_536}
      ])

    state = State.build(port, opts)

    {:ok, EventEmitter.emit(state, :transport_started, %{})}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Snapshot.build(state), state}
  end

  @impl true
  def handle_call({:call_parent, method, params, opts}, from, state) do
    ParentCall.handle_call(state, from, method, params, opts, @default_timeout, now_ms())
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    {:noreply, state |> touch() |> StreamProcessor.handle_line(line)}
  end

  def handle_info({port, {:data, {:noeol, line}}}, %{port: port} = state) do
    {:noreply, state |> touch() |> StreamProcessor.handle_line(line)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = {:port_exit, status}

    state =
      state.pending
      |> Enum.reduce(state, fn {request_id, pending}, acc ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, {:error, reason})

        EventEmitter.emit(acc, :parent_call_failed, %{
          external_ids: pending.external_ids,
          request_id: request_id,
          error: reason
        })
      end)
      |> Map.put(:pending, %{})
      |> EventEmitter.emit(:transport_exited, %{error: reason})

    {:stop, reason, state}
  end

  def handle_info({:request_timeout, request_id}, state) do
    case PendingRequest.pop(state, request_id) do
      {nil, state} ->
        {:noreply, state}

      {pending, state} ->
        error = {:timeout, request_id}
        GenServer.reply(pending.from, {:error, error})

        state =
          state
          |> EventEmitter.emit(:parent_call_failed, %{
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
        |> Cleanup.close_owned_port()
        |> EventEmitter.emit(:transport_cleanup, %{
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
    Cleanup.close_port(port)
    :ok
  end

  defp fail_pending(state, reason) do
    state.pending
    |> Enum.each(fn {_request_id, pending} ->
      Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, {:error, reason})
    end)

    PendingRequest.clear(state)
  end

  defp touch(state), do: Cleanup.touch(state)

  defp now_ms, do: System.system_time(:millisecond)
end
