defmodule Ourocode.MCP.Transport.StreamableHTTP do
  @moduledoc """
  Streamable HTTP MCP transport.

  This module executes a parent JSON-RPC MCP call over HTTP, emits the
  transport-level parent call result to an optional subscriber, and can append
  decoded lifecycle events to the local journal. It intentionally owns only
  transport concerns; pane state and runtime routing are handled by higher-level
  OTP processes.
  """

  use GenServer

  alias Ourocode.MCP.ParentCallResult
  alias Ourocode.MCP.Transport.Http
  alias Ourocode.MCP.Transport.StreamableHTTP.CallContext
  alias Ourocode.MCP.Transport.StreamableHTTP.EventEmitter
  alias Ourocode.MCP.Transport.StreamableHTTP.LifecycleNormalizer
  alias Ourocode.MCP.Transport.StreamableHTTP.Post
  alias Ourocode.MCP.Transport.StreamableHTTP.RawEvent
  alias Ourocode.MCP.Transport.StreamableHTTP.Response
  alias Ourocode.MCP.Transport.StreamableHTTP.ResponseEvents
  alias Ourocode.MCP.Transport.StreamableHTTP.Session

  @default_timeout 5_000
  @protocol_version "2025-06-18"

  @type option ::
          {:url, String.t()}
          | {:parent_call_id, String.t()}
          | {:runtime_source, String.t()}
          | {:external_ids, map()}
          | {:subscriber, pid()}
          | {:journal_path, Path.t()}
          | {:headers, [{String.t(), String.t()}]}
          | {:event_seq, non_neg_integer()}
          | {:timeout, pos_integer()}
          | {:name, GenServer.name()}

  defstruct options: []

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

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec call_parent(GenServer.server(), String.t(), map() | list() | nil, keyword()) ::
          {:ok, ParentCallResult.t()} | {:error, term()}
  def call_parent(server, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_list(opts) do
    request_id = opts |> Keyword.get(:request_id, "call-1") |> to_string()
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    request = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => method,
      "params" => params
    }

    GenServer.call(server, {:call_parent, request, opts}, timeout + 1_000)
  end

  @spec execute_parent_call([option()], map()) ::
          {:ok, ParentCallResult.t()} | {:error, term()}
  def execute_parent_call(options, request) when is_list(options) and is_map(request) do
    with {:ok, url} <- fetch_option(options, :url),
         :ok <- ensure_http_started(),
         {:ok, options} <- ensure_mcp_session(url, options),
         :ok <- emit_started(options, request),
         {:ok, {{_, status, _reason}, raw_headers, body}} <-
           Post.json(url, request, options, @default_timeout, &emit_event(options, &1)),
         headers = Http.normalize_headers(raw_headers),
         {:ok, response} <- decode_response(status, headers, body) do
      result = CallContext.result(options, status, headers, response)

      unless Http.event_stream?(headers) do
        emit_response_events(options, request, status, headers, body)
      end

      {:ok, result}
    end
  end

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{options: opts}}
  end

  @impl true
  def handle_call({:call_parent, request, opts}, _from, state) do
    options =
      state.options
      |> Keyword.merge(opts)
      |> Keyword.put(:event_seq, CallContext.next_event_seq(state.options))

    {:reply, execute_parent_call(options, request), %{state | options: options}}
  end

  defp fetch_option(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp ensure_http_started do
    case :inets.start() do
      :ok -> :ok
      {:error, {:already_started, :inets}} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {:inets_start_failed, reason}}
    end
  end

  defp ensure_mcp_session(url, options) do
    Session.ensure(url, options, @protocol_version, @default_timeout)
  end

  defp decode_response(status, headers, body), do: Response.decode(status, headers, body)

  defp emit_started(options, request) do
    context = CallContext.normalizer(options, request, Keyword.get(options, :event_seq, 1))

    event =
      context
      |> LifecycleNormalizer.started()
      |> Map.put(:raw_event, build_raw_request_event_record(options, request, context))

    emit_event(options, event)
  end

  defp emit_response_events(options, request, status, headers, body) do
    options
    |> ResponseEvents.build(request, status, headers, body)
    |> Enum.each(&emit_event(options, &1))
  end

  defp emit_event(options, event) do
    EventEmitter.emit(options, event)
  end

  @doc false
  @spec canonical_journal_event(Ourocode.MCP.LifecycleEvent.t() | map()) :: map()
  def canonical_journal_event(event), do: EventEmitter.canonical_journal_event(event)

  @doc false
  @spec build_raw_request_event_record(keyword(), map(), map()) :: map()
  def build_raw_request_event_record(options, request, context)
      when is_list(options) and is_map(request) and is_map(context) do
    RawEvent.build_request_record(options, request, context)
  end

  @doc false
  @spec build_raw_response_event_record(keyword(), map(), map()) :: map()
  def build_raw_response_event_record(options, raw_event, context)
      when is_list(options) and is_map(raw_event) and is_map(context) do
    RawEvent.build_response_record(options, raw_event, context)
  end

  defp default_child_id(opts) do
    {__MODULE__, Keyword.get(opts, :parent_call_id), Keyword.get(opts, :url)}
  end
end
