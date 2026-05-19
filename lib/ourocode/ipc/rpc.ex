defmodule Ourocode.IPC.RPC do
  @moduledoc """
  Elixir-owned RPC invoker for replaceable helper workers.

  Helpers communicate over the agreed IPC transport: one newline-delimited JSON
  frame per `Ourocode.IPC.Request` or `Ourocode.IPC.Response` envelope on
  stdio. This module owns request IDs, response correlation, helper port
  lifecycle, and timeout cleanup; Rust helpers remain replaceable external
  workers and never own Ourocode state.
  """

  use GenServer

  alias Ourocode.IPC.Request
  alias Ourocode.IPC.Response

  @default_timeout 5_000
  @app :ourocode

  defstruct [
    :helper,
    :command,
    :args,
    :codec,
    request_seq: 0,
    pending: %{},
    ports: %{}
  ]

  @type invoke_option ::
          {:metadata, map()}
          | {:request_id, String.t()}
          | {:timeout, timeout()}

  @doc """
  Starts an RPC invoker around a helper executable.

  Required options:
    * `:command` - executable path used as an inline helper, or
    * `:helper` - configured Rust helper name to resolve on each invocation

  Optional:
    * `:args` - executable args
    * `:codec` - JSON codec module
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [Keyword.delete(opts, :id)]},
      restart: Keyword.get(opts, :restart, :permanent),
      shutdown: Keyword.get(opts, :shutdown, 5_000),
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Invokes a helper method/action and waits for the correlated response.
  """
  @spec invoke(GenServer.server(), String.t(), String.t(), map(), [invoke_option()]) ::
          {:ok, map()} | {:error, term()}
  def invoke(server, method, action, params \\ %{}, opts \\ [])
      when is_binary(method) and is_binary(action) and is_map(params) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, timeout} <- normalize_timeout(timeout) do
      opts = Keyword.put(opts, :timeout, timeout)
      GenServer.call(server, {:invoke, method, action, params, opts}, call_timeout(timeout))
    end
  end

  @impl true
  def init(opts) do
    helper = Keyword.get(opts, :helper)
    command = Keyword.get(opts, :command)

    cond do
      is_nil(helper) and is_nil(command) ->
        {:stop, {:transport_start_failed, "missing :command or configured :helper"}}

      true ->
        {:ok,
         %__MODULE__{
           helper: helper,
           command: command,
           args: Keyword.get(opts, :args, []),
           codec: Keyword.get(opts, :codec, Ourocode.Json)
         }}
    end
  end

  @impl true
  def handle_call({:invoke, method, action, params, opts}, from, state) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    request_id = Keyword.get(opts, :request_id, next_request_id(state))
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, request} <- Request.new(request_id, method, action, params, metadata),
         {:ok, frame} <- Request.serialize_line(request, state.codec),
         {:ok, helper_config} <- resolve_helper(state),
         {:ok, port} <- open_port_and_write(helper_config.command, helper_config.args, frame) do
      timer = schedule_request_timeout(request.message_id, timeout)

      pending = %{
        from: from,
        timer: timer,
        method: request.method,
        action: request.action,
        port: port,
        helper: Map.take(helper_config, [:name, :command, :version])
      }

      state =
        state
        |> Map.update!(:request_seq, &(&1 + 1))
        |> Map.update!(:pending, &Map.put(&1, request.message_id, pending))
        |> Map.update!(:ports, &Map.put(&1, port, request.message_id))

      {:noreply, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, state) do
    if Map.has_key?(state.ports, port) do
      {:noreply, handle_line(state, line)}
    else
      {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:noeol, line}}}, state) do
    if Map.has_key?(state.ports, port) do
      {:noreply, handle_line(state, line)}
    else
      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) do
    if Map.has_key?(state.ports, port) do
      {:noreply, fail_port_pending(state, port, {:port_exit, status})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:request_timeout, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        {:noreply, state}

      {pending, pending_map} ->
        close_port(pending.port)

        GenServer.reply(pending.from, {:error, {:timeout, request_id}})
        {:noreply, %{state | pending: pending_map, ports: Map.delete(state.ports, pending.port)}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state.ports
    |> Map.keys()
    |> Enum.each(&close_port/1)

    :ok
  end

  defp handle_line(state, line) do
    case Response.deserialize_line(line, state.codec) do
      {:ok, response} ->
        complete_response(state, response)

      {:error, reason} ->
        fail_pending(state, {:malformed_response, reason})
    end
  end

  defp complete_response(state, %Response{} = response) do
    case Map.pop(state.pending, response.request_id) do
      {nil, _pending} ->
        state

      {pending, pending_map} ->
        cancel_request_timeout(pending.timer)
        close_port(pending.port)
        GenServer.reply(pending.from, response_reply(response))
        %{state | pending: pending_map, ports: Map.delete(state.ports, pending.port)}
    end
  end

  defp response_reply(%Response{status: "ok", result: result}), do: {:ok, result}
  defp response_reply(%Response{status: "error", error: error}), do: {:error, error}

  defp open_port(command, args) do
    {:ok,
     Port.open({:spawn_executable, command}, [
       :binary,
       :exit_status,
       {:args, args},
       {:line, 65_536}
     ])}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp open_port_and_write(command, args, frame) do
    with {:ok, port} <- open_port(command, args) do
      case write_frame(port, frame) do
        :ok ->
          {:ok, port}

        {:error, reason} ->
          close_port(port)
          {:error, reason}
      end
    end
  end

  defp resolve_helper(%{helper: helper}) when not is_nil(helper) do
    helper
    |> configured_helper()
    |> normalize_helper_config(helper)
  end

  defp resolve_helper(%{command: command, args: args}) do
    normalize_helper_config(%{command: command, args: args}, :inline)
  end

  defp configured_helper(helper) do
    helpers = Application.get_env(@app, :rust_helpers, %{})
    helper_key = helper_key(helper)

    cond do
      is_map(helpers) and Map.has_key?(helpers, helper) ->
        Map.fetch!(helpers, helper)

      is_map(helpers) and is_binary(helper_key) and Map.has_key?(helpers, helper_key) ->
        Map.fetch!(helpers, helper_key)

      true ->
        nil
    end
  end

  defp helper_key(helper) when is_atom(helper), do: Atom.to_string(helper)
  defp helper_key(helper) when is_binary(helper), do: helper
  defp helper_key(_helper), do: nil

  defp normalize_helper_config(nil, helper) do
    {:error, {:missing_helper_config, helper}}
  end

  defp normalize_helper_config(config, helper) when is_map(config) do
    command = Map.get(config, :command) || Map.get(config, "command") || Map.get(config, :path) ||
      Map.get(config, "path")
    args = Map.get(config, :args) || Map.get(config, "args") || []
    version = Map.get(config, :version) || Map.get(config, "version")

    cond do
      not is_binary(command) or String.trim(command) == "" ->
        {:error, {:invalid_helper_command, helper}}

      not is_list(args) or not Enum.all?(args, &is_binary/1) ->
        {:error, {:invalid_helper_args, helper}}

      not is_nil(version) and not is_binary(version) ->
        {:error, {:invalid_helper_version, helper}}

      true ->
        {:ok, %{name: helper, command: command, args: args, version: version}}
    end
  end

  defp normalize_helper_config(command, helper) when is_binary(command) do
    normalize_helper_config(%{command: command}, helper)
  end

  defp normalize_helper_config(_config, helper) do
    {:error, {:invalid_helper_config, helper}}
  end

  defp fail_pending(state, reason) do
    state.pending
    |> Enum.reduce(state, fn {_request_id, pending}, acc ->
      cancel_request_timeout(pending.timer)
      close_port(pending.port)
      GenServer.reply(pending.from, {:error, reason})
      acc
    end)
    |> Map.put(:pending, %{})
    |> Map.put(:ports, %{})
  end

  defp fail_port_pending(state, port, reason) do
    case Map.pop(state.ports, port) do
      {nil, ports} ->
        %{state | ports: ports}

      {request_id, ports} ->
        case Map.pop(state.pending, request_id) do
          {nil, pending} ->
            %{state | pending: pending, ports: ports}

          {pending_call, pending} ->
            cancel_request_timeout(pending_call.timer)
            GenServer.reply(pending_call.from, {:error, reason})
            %{state | pending: pending, ports: ports}
        end
    end
  end

  defp write_frame(port, frame) do
    if Port.command(port, frame) do
      :ok
    else
      {:error, :closed}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp next_request_id(state), do: "ipc-req-" <> Integer.to_string(state.request_seq + 1)

  defp normalize_timeout(:infinity), do: {:ok, :infinity}
  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: {:ok, timeout}
  defp normalize_timeout(timeout), do: {:error, {:invalid_timeout, timeout}}

  defp schedule_request_timeout(_request_id, :infinity), do: nil

  defp schedule_request_timeout(request_id, timeout) do
    Process.send_after(self(), {:request_timeout, request_id}, timeout)
  end

  defp cancel_request_timeout(nil), do: :ok
  defp cancel_request_timeout(timer), do: Process.cancel_timer(timer)

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout), do: timeout + 1_000

  defp close_port(port) do
    if Port.info(port) do
      Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end
end
