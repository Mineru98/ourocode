defmodule Ourocode.MCP.Transport.SSE do
  @moduledoc """
  SSE MCP transport connection.

  The process establishes one long-lived `text/event-stream` HTTP connection,
  parses SSE frames as they arrive, and emits journal-ready lifecycle events.
  It owns only transport concerns; higher-level OTP processes own pane state,
  journal persistence, child session mapping, and runtime routing.
  """

  use GenServer

  alias Ourocode.Journal
  alias Ourocode.Json
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.SSE.Parser
  alias Ourocode.MCP.Transport.SSE.LifecycleNormalizer

  @default_timeout 5_000

  @type option ::
          {:url, String.t()}
          | {:parent_call_id, String.t()}
          | {:runtime_source, String.t()}
          | {:external_ids, map()}
          | {:event_sink, pid() | (LifecycleEvent.t() -> term())}
          | {:dispatch_url, String.t()}
          | {:headers, [{String.t(), String.t()}]}
          | {:event_seq, non_neg_integer()}
          | {:journal_path, Path.t()}
          | {:raw_payload_store_dir, Path.t()}
          | {:timeout, pos_integer()}
          | {:await_response, boolean()}
          | {:connection_identifier, String.t()}
          | {:session_identifier, String.t()}
          | {:name, GenServer.name()}

  defstruct [
    :socket,
    :event_sink,
    :parent_call_id,
    :runtime_source,
    :external_ids,
    :dispatch_uri,
    :endpoint_url,
    :connection_identifier,
    :session_identifier,
    :request_headers,
    :journal_path,
    :raw_payload_store_dir,
    :status,
    :headers,
    event_seq: 0,
    request_seq: 0,
    pending: %{},
    response_buffer: "",
    sse_buffer: ""
  ]

  @doc """
  Starts and connects an SSE transport process.

  Required options:
    * `:url` - HTTP SSE endpoint URL

  Useful options:
    * `:event_sink` - pid or one-arity function that receives lifecycle events
    * `:parent_call_id` - local parent call mapping ID
    * `:runtime_source` - external runtime source name
    * `:external_ids` - trusted runtime IDs/status map
    * `:dispatch_url` - HTTP endpoint used to POST parent JSON-RPC requests
    * `:headers` - additional HTTP headers
    * `:journal_path` - JSONL local journal path for persisted lifecycle events
    * `:raw_payload_store_dir` - sidecar directory for raw SSE frame bytes
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Dispatches a parent MCP JSON-RPC request over the established SSE transport.

  SSE receives server events on the long-lived stream, while JSON-RPC requests
  are posted to the configured message endpoint. Results and progress continue
  to arrive asynchronously through the SSE stream and are emitted as lifecycle
  events.
  """
  @spec call_parent(GenServer.server(), String.t(), map() | list() | nil, keyword()) ::
          {:ok, term()}
          | {:error, term()}
  def call_parent(server, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(server, {:call_parent, method, params, opts}, timeout + 1_000)
  end

  @doc false
  @spec build_raw_event_record(map(), map()) :: map()
  def build_raw_event_record(%{} = raw_event, context) when is_map(context) do
    timestamp_ms = Map.get(context, :timestamp_ms, System.system_time(:millisecond))
    sse_event_id_present = sse_field_present?(raw_event, context, :sse_event_id_present, "id")

    sse_event_type_present =
      sse_field_present?(raw_event, context, :sse_event_type_present, "event")

    {raw_payload_ref, raw_payload_stored?, raw_payload_size_bytes} =
      raw_payload_record_metadata(context)

    Map.merge(raw_event, %{
      transport: :sse,
      transport_type: :sse,
      endpoint_url: Map.fetch!(context, :endpoint_url),
      connection_identifier: Map.fetch!(context, :connection_identifier),
      session_identifier: Map.fetch!(context, :session_identifier),
      sse_event_id:
        sse_field_value(raw_event, context, :sse_event_id, "id", sse_event_id_present),
      sse_event_id_present: sse_event_id_present,
      sse_event_type:
        sse_field_value(raw_event, context, :sse_event_type, "event", sse_event_type_present),
      sse_event_type_present: sse_event_type_present,
      timestamp_ms: timestamp_ms,
      received_at_ms: timestamp_ms,
      raw_payload_ref: raw_payload_ref,
      raw_payload_stored?: raw_payload_stored?,
      raw_payload_size_bytes: raw_payload_size_bytes
    })
    |> Map.delete(:raw_payload)
    |> Map.delete("raw_payload")
    |> Map.delete(:frame)
    |> Map.delete("frame")
  end

  @impl true
  def init(opts) do
    with {:ok, url} <- Keyword.fetch(opts, :url),
         {:ok, uri} <- parse_url(url),
         {:ok, socket} <- connect(uri, Keyword.get(opts, :timeout, @default_timeout)),
         :ok <- send_request(socket, uri, Keyword.get(opts, :headers, [])) do
      external_ids = Keyword.get(opts, :external_ids, %{})

      state = %__MODULE__{
        socket: socket,
        event_sink: Keyword.get(opts, :event_sink, self()),
        parent_call_id: Keyword.get(opts, :parent_call_id, new_id("parent")),
        runtime_source: Keyword.get(opts, :runtime_source, "synthetic"),
        external_ids: external_ids,
        dispatch_uri: parse_optional_dispatch_url(Keyword.get(opts, :dispatch_url)),
        endpoint_url: URI.to_string(uri),
        connection_identifier:
          Keyword.get(opts, :connection_identifier, new_id("sse-connection")),
        session_identifier:
          Keyword.get(opts, :session_identifier, sse_session_identifier(uri, external_ids)),
        request_headers: Keyword.get(opts, :headers, []),
        journal_path: Keyword.get(opts, :journal_path),
        raw_payload_store_dir:
          Keyword.get(opts, :raw_payload_store_dir) ||
            default_raw_payload_store_dir(Keyword.get(opts, :journal_path)),
        event_seq: Keyword.get(opts, :event_seq, 0)
      }

      :inet.setopts(socket, active: :once)
      {:ok, state}
    else
      :error -> {:stop, {:missing_option, :url}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:call_parent, method, params, opts}, from, state) do
    request_id = opts |> Keyword.get(:request_id, state.request_seq + 1) |> to_string()
    request = %{"jsonrpc" => "2.0", "id" => request_id, "method" => method, "params" => params}
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case dispatch_request(state, request, timeout) do
      {:ok, status, response} ->
        next_state =
          state
          |> Map.update!(:request_seq, &(&1 + 1))
          |> emit(:parent_call_started, %{
            request_id: request_id,
            method: method,
            params: params,
            status: status,
            raw_event: request
          })

        if Keyword.get(opts, :await_response, false) do
          timer = Process.send_after(self(), {:request_timeout, request_id}, timeout)

          pending = %{
            from: from,
            method: method,
            params: params,
            timer: timer
          }

          {:noreply, Map.update!(next_state, :pending, &Map.put(&1, request_id, pending))}
        else
          {:reply, {:ok, %{request_id: request_id, status: status, response: response}},
           next_state}
        end

      {:error, reason} ->
        next_state =
          emit(state, :parent_call_write_failed, %{
            request_id: request_id,
            method: method,
            params: params,
            error: reason,
            raw_event: request
          })

        {:reply, {:error, reason}, next_state}
    end
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
            request_id: request_id,
            method: pending.method,
            params: pending.params,
            error: error
          })

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, chunk}, %{socket: socket, status: nil} = state) do
    state = handle_response_chunk(%{state | response_buffer: state.response_buffer <> chunk})
    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp, socket, chunk}, %{socket: socket} = state) do
    state = handle_sse_chunk(%{state | sse_buffer: state.sse_buffer <> chunk})
    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    {:stop, :normal, state |> fail_pending(:transport_closed) |> emit(:transport_closed, %{})}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    {:stop, reason, state |> fail_pending(reason) |> emit(:transport_failed, %{error: reason})}
  end

  @impl true
  def terminate(_reason, %{socket: socket}) when is_port(socket) do
    :gen_tcp.close(socket)
    :ok
  end

  defp parse_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "http" -> {:error, {:unsupported_scheme, uri.scheme}}
      is_nil(uri.host) -> {:error, {:invalid_url, url}}
      true -> {:ok, uri}
    end
  end

  defp parse_optional_dispatch_url(nil), do: nil

  defp parse_optional_dispatch_url(url) do
    case parse_url(url) do
      {:ok, uri} -> uri
      {:error, reason} -> raise ArgumentError, "invalid SSE dispatch_url: #{inspect(reason)}"
    end
  end

  defp connect(uri, timeout) do
    host = String.to_charlist(uri.host)
    port = uri.port || 80

    :gen_tcp.connect(host, port, [:binary, packet: :raw, active: false], timeout)
  end

  defp send_request(socket, uri, headers) do
    host_header =
      if uri.port && uri.port != 80 do
        "#{uri.host}:#{uri.port}"
      else
        uri.host
      end

    request_headers =
      [
        {"host", host_header},
        {"accept", "text/event-stream"},
        {"cache-control", "no-cache"},
        {"connection", "keep-alive"}
      ] ++ headers

    request = [
      "GET ",
      request_target(uri),
      " HTTP/1.1\r\n",
      Enum.map(request_headers, fn {key, value} ->
        [to_string(key), ": ", to_string(value), "\r\n"]
      end),
      "\r\n"
    ]

    case :gen_tcp.send(socket, request) do
      :ok -> :ok
      {:error, reason} -> {:error, {:request_send_failed, reason}}
    end
  end

  defp request_target(uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path

    case uri.query do
      nil -> path
      "" -> path
      query -> path <> "?" <> query
    end
  end

  defp dispatch_request(%{dispatch_uri: nil}, _request, _timeout) do
    {:error, :missing_dispatch_url}
  end

  defp dispatch_request(%{status: nil}, _request, _timeout) do
    {:error, :sse_not_connected}
  end

  defp dispatch_request(state, request, timeout) do
    with :ok <- ensure_http_started(),
         {:ok, {{_, status, _reason}, _headers, body}} <-
           post_json(state.dispatch_uri, request, state.request_headers || [], timeout),
         {:ok, response} <- decode_dispatch_response(status, body) do
      {:ok, status, response}
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

  defp post_json(uri, request, headers, timeout) do
    body = request |> Json.encode!() |> IO.iodata_to_binary() |> String.to_charlist()

    request_headers =
      [
        {~c"accept", ~c"application/json, text/event-stream"}
      ] ++ charlist_headers(headers)

    :httpc.request(
      :post,
      {uri |> URI.to_string() |> String.to_charlist(), request_headers, ~c"application/json",
       body},
      [timeout: timeout, connect_timeout: timeout],
      body_format: :binary
    )
  end

  defp decode_dispatch_response(status, body) when status in 200..299 do
    case String.trim(to_string(body)) do
      "" -> {:ok, nil}
      response_body -> Json.decode(response_body)
    end
  end

  defp decode_dispatch_response(status, body) do
    {:error, {:http_error, status, body}}
  end

  defp charlist_headers(headers) do
    headers
    |> Enum.reject(fn {key, _value} ->
      String.downcase(to_string(key)) in ["content-type", "accept"]
    end)
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end

  defp handle_response_chunk(state) do
    case String.split(state.response_buffer, "\r\n\r\n", parts: 2) do
      [headers_blob, rest] ->
        case parse_response_headers(headers_blob) do
          {:ok, status, headers} when status in 200..299 ->
            state
            |> Map.put(:status, status)
            |> Map.put(:headers, headers)
            |> Map.put(:response_buffer, "")
            |> Map.put(:sse_buffer, rest)
            |> connect_or_reject_sse()

          {:ok, status, headers} ->
            state
            |> Map.put(:status, status)
            |> Map.put(:headers, headers)
            |> Map.put(:response_buffer, "")
            |> emit(:transport_failed, %{error: {:http_error, status}})

          {:error, reason} ->
            emit(state, :transport_failed, %{error: reason})
        end

      [_partial] ->
        state
    end
  end

  defp connect_or_reject_sse(state) do
    if event_stream?(state.headers) do
      state
      |> emit(:transport_connected, %{})
      |> handle_sse_chunk()
    else
      emit(state, :transport_failed, %{error: :missing_event_stream_content_type})
    end
  end

  defp parse_response_headers(headers_blob) do
    [status_line | header_lines] = String.split(headers_blob, "\r\n")

    with [_, status_text | _] <- String.split(status_line, " ", parts: 3),
         {status, ""} <- Integer.parse(status_text) do
      headers =
        header_lines
        |> Enum.flat_map(fn line ->
          case String.split(line, ":", parts: 2) do
            [key, value] -> [{String.downcase(key), String.trim_leading(value)}]
            _ -> []
          end
        end)

      {:ok, status, headers}
    else
      _ -> {:error, {:invalid_response_headers, headers_blob}}
    end
  end

  defp event_stream?(headers) do
    Enum.any?(headers, fn {key, value} ->
      String.downcase(key) == "content-type" and
        value |> String.downcase() |> String.contains?("text/event-stream")
    end)
  end

  defp handle_sse_chunk(state) do
    {frames, rest} = Parser.split_complete_frames(state.sse_buffer)

    state
    |> Map.put(:sse_buffer, rest)
    |> then(fn next_state -> Enum.reduce(frames, next_state, &handle_sse_frame/2) end)
  end

  defp handle_sse_frame(frame, state) do
    raw_context = raw_event_context(state, frame)

    case Parser.parse_frame(frame) do
      {:ok, nil} ->
        state

      {:ok, event} ->
        emit_json_rpc_event(state, annotate_raw_event(event, raw_context))

      {:error, reason} ->
        emit(state, :transport_decode_failed, %{
          error: reason,
          raw_event: annotate_raw_event(%{frame: frame}, raw_context)
        })
    end
  end

  defp emit_json_rpc_event(state, %{"data" => %{"id" => request_id, "result" => result}} = event) do
    complete_parent_call(state, to_string(request_id), {:ok, result}, event)
  end

  defp emit_json_rpc_event(state, %{"data" => %{"id" => request_id, "error" => error}} = event) do
    complete_parent_call(state, to_string(request_id), {:error, error}, event)
  end

  defp emit_json_rpc_event(state, %{"data" => %{"method" => _method}} = event) do
    emit_normalized(
      state,
      LifecycleNormalizer.normalize_parsed_event(event, event_context(state))
    )
  end

  defp emit_json_rpc_event(state, %{"data" => _decoded} = event) do
    emit_normalized(
      state,
      LifecycleNormalizer.normalize_parsed_event(event, event_context(state))
    )
  end

  defp emit_json_rpc_event(state, %{"metadata" => _metadata} = event) do
    emit_normalized(
      state,
      LifecycleNormalizer.normalize_parsed_event(event, event_context(state))
    )
  end

  defp complete_parent_call(state, request_id, reply, sse_event) do
    {pending, pending_map} = Map.pop(state.pending, request_id)

    if pending do
      Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, reply)
    end

    context =
      state
      |> event_context()
      |> Map.put(:method, pending && pending.method)
      |> Map.put(:params, pending && pending.params)

    state
    |> Map.put(:pending, pending_map)
    |> emit_normalized(LifecycleNormalizer.normalize_parsed_event(sse_event, context))
  end

  defp fail_pending(state, reason) do
    Enum.reduce(state.pending, %{state | pending: %{}}, fn {request_id, pending}, acc ->
      Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, {:error, reason})

      emit(acc, :parent_call_failed, %{
        request_id: request_id,
        method: pending.method,
        params: pending.params,
        error: reason
      })
    end)
  end

  defp emit(state, type, payload) do
    event =
      %{
        event_seq: state.event_seq + 1,
        type: type,
        transport: :sse,
        parent_call_id: state.parent_call_id,
        runtime_source: state.runtime_source,
        external_ids: state.external_ids,
        occurred_at_ms: System.system_time(:millisecond),
        status: state.status,
        headers: state.headers
      }
      |> Map.merge(Map.new(payload))
      |> then(&LifecycleEvent.new(type, &1))

    persist(state.journal_path, event)
    deliver(state.event_sink, event)
    %{state | event_seq: event.event_seq}
  end

  defp emit_normalized(state, %LifecycleEvent{} = event) do
    persist(state.journal_path, event)
    deliver(state.event_sink, event)
    %{state | event_seq: event.event_seq}
  end

  defp annotate_raw_event(%{} = raw_event, raw_context) when is_map(raw_context) do
    build_raw_event_record(raw_event, raw_context)
  end

  defp raw_event_context(state, raw_payload) do
    timestamp_ms = System.system_time(:millisecond)
    sse_fields = sse_frame_metadata(raw_payload)
    raw_payload_ref = raw_payload_ref(raw_payload)

    raw_payload_stored? =
      store_raw_payload(state.raw_payload_store_dir, raw_payload, raw_payload_ref)

    Map.merge(
      %{
        endpoint_url: state.endpoint_url,
        connection_identifier: state.connection_identifier,
        session_identifier: state.session_identifier,
        timestamp_ms: timestamp_ms,
        raw_payload_ref: raw_payload_ref,
        raw_payload_stored?: raw_payload_stored?,
        raw_payload_size_bytes: byte_size(raw_payload)
      },
      sse_fields
    )
  end

  defp sse_frame_metadata(frame) when is_binary(frame) do
    fields =
      frame
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.trim_leading/1)
      |> Enum.reject(&String.starts_with?(&1, ":"))
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] when key in ["id", "event"] ->
            Map.put(acc, key, strip_sse_value_prefix(value))

          [key] when key in ["id", "event"] ->
            Map.put(acc, key, "")

          _line ->
            acc
        end
      end)

    %{
      sse_event_id: Map.get(fields, "id"),
      sse_event_id_present: Map.has_key?(fields, "id"),
      sse_event_type: Map.get(fields, "event"),
      sse_event_type_present: Map.has_key?(fields, "event")
    }
  end

  defp sse_frame_metadata(_raw_payload) do
    %{
      sse_event_id: nil,
      sse_event_id_present: false,
      sse_event_type: nil,
      sse_event_type_present: false
    }
  end

  defp sse_field_present?(raw_event, context, context_key, raw_key) do
    case Map.fetch(context, context_key) do
      {:ok, value} when is_boolean(value) -> value
      _missing -> Map.has_key?(raw_event, raw_key)
    end
  end

  defp sse_field_value(raw_event, context, context_key, raw_key, true) do
    if Map.has_key?(context, context_key) do
      Map.get(context, context_key)
    else
      Map.get(raw_event, raw_key)
    end
  end

  defp sse_field_value(raw_event, context, context_key, raw_key, false) do
    if Map.has_key?(context, context_key) do
      Map.get(context, context_key)
    else
      Map.get(raw_event, raw_key)
    end
  end

  defp strip_sse_value_prefix(" " <> value), do: value
  defp strip_sse_value_prefix(value), do: value

  defp raw_payload_ref(raw_payload) when is_binary(raw_payload) do
    "sha256:" <> raw_payload_digest(raw_payload)
  end

  defp raw_payload_record_metadata(%{raw_payload: raw_payload} = context)
       when is_binary(raw_payload) do
    raw_payload_ref = Map.get(context, :raw_payload_ref) || raw_payload_ref(raw_payload)

    raw_payload_stored? =
      Map.get(context, :raw_payload_stored?) ||
        store_raw_payload(raw_payload_store_dir(context), raw_payload, raw_payload_ref)

    {raw_payload_ref, raw_payload_stored?, byte_size(raw_payload)}
  end

  defp raw_payload_record_metadata(%{"raw_payload" => raw_payload} = context)
       when is_binary(raw_payload) do
    raw_payload_ref = Map.get(context, :raw_payload_ref) || raw_payload_ref(raw_payload)

    raw_payload_stored? =
      Map.get(context, :raw_payload_stored?) ||
        store_raw_payload(raw_payload_store_dir(context), raw_payload, raw_payload_ref)

    {raw_payload_ref, raw_payload_stored?, byte_size(raw_payload)}
  end

  defp raw_payload_record_metadata(context) do
    {Map.get(context, :raw_payload_ref), Map.get(context, :raw_payload_stored?, false),
     Map.get(context, :raw_payload_size_bytes)}
  end

  defp raw_payload_store_dir(context) do
    Map.get(context, :raw_payload_store_dir) || Map.get(context, "raw_payload_store_dir")
  end

  @doc false
  @spec raw_payload_path(Path.t(), String.t()) :: Path.t()
  def raw_payload_path(store_dir, "sha256:" <> digest) when is_binary(store_dir) do
    Path.join(store_dir, "sha256-" <> digest <> ".raw")
  end

  defp store_raw_payload(nil, _raw_payload, _raw_payload_ref), do: false

  defp store_raw_payload(store_dir, raw_payload, raw_payload_ref)
       when is_binary(store_dir) and is_binary(raw_payload) do
    path = raw_payload_path(store_dir, raw_payload_ref)

    with :ok <- File.mkdir_p(store_dir),
         :ok <- write_raw_payload_once(path, raw_payload) do
      true
    else
      _ -> false
    end
  end

  defp write_raw_payload_once(path, raw_payload) do
    case File.write(path, raw_payload, [:binary, :exclusive]) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.read(path) do
          {:ok, ^raw_payload} -> :ok
          {:ok, _different_payload} -> {:error, :raw_payload_digest_collision}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp raw_payload_digest(raw_payload) when is_binary(raw_payload) do
    :crypto.hash(:sha256, raw_payload)
    |> Base.encode16(case: :lower)
  end

  defp default_raw_payload_store_dir(nil), do: nil
  defp default_raw_payload_store_dir(journal_path), do: journal_path <> ".raw_sse_payloads"

  defp sse_session_identifier(uri, external_ids) do
    external_session_identifier(external_ids) || query_session_identifier(uri) ||
      request_target(uri)
  end

  defp external_session_identifier(external_ids) when is_map(external_ids) do
    Map.get(external_ids, "session_id") ||
      Map.get(external_ids, :session_id) ||
      Map.get(external_ids, "sessionId") ||
      Map.get(external_ids, :sessionId)
  end

  defp query_session_identifier(%{query: nil}), do: nil
  defp query_session_identifier(%{query: ""}), do: nil

  defp query_session_identifier(uri) do
    uri.query
    |> URI.decode_query()
    |> Map.get("session")
  rescue
    ArgumentError -> nil
  end

  defp event_context(state) do
    %{
      event_seq: state.event_seq + 1,
      parent_call_id: state.parent_call_id,
      runtime_source: state.runtime_source,
      external_ids: state.external_ids,
      occurred_at_ms: System.system_time(:millisecond),
      status: state.status,
      headers: state.headers
    }
  end

  defp persist(nil, _event), do: :ok

  defp persist(path, event) when is_binary(path) do
    Journal.append!(path, canonical_journal_event(event))
  end

  @doc false
  @spec canonical_journal_event(LifecycleEvent.t() | map()) :: map()
  def canonical_journal_event(%LifecycleEvent{} = event) do
    event
    |> Map.from_struct()
    |> compact_journal_event()
  end

  def canonical_journal_event(%{} = event) do
    compact_journal_event(event)
  end

  defp compact_journal_event(event) do
    event
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp deliver(pid, event) when is_pid(pid), do: send(pid, {:ourocode_event, event})
  defp deliver(fun, event) when is_function(fun, 1), do: fun.(event)
  defp deliver(_sink, _event), do: :ok

  defp new_id(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
