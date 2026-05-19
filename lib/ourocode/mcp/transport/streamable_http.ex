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

  alias Ourocode.Json
  alias Ourocode.Journal
  alias Ourocode.MCP.ParentCallResult
  alias Ourocode.MCP.Transport.StreamableHTTP.LifecycleNormalizer

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
         {:ok, {{_, status, _reason}, raw_headers, body}} <- post_json(url, request, options),
         headers = normalize_headers(raw_headers),
         {:ok, response} <- decode_response(status, headers, body) do
      result = build_result(options, status, headers, response)

      unless event_stream?(headers) do
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
      |> Keyword.put(:event_seq, next_event_seq(state.options))

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

  # MCP Streamable HTTP requires a session: `initialize` → the server returns
  # an `mcp-session-id` header → `notifications/initialized` → every later
  # request (e.g. tools/call) must carry that header. Without this the server
  # answers `400 Bad Request: Missing session ID` and no interview ever
  # streams. The session header is injected into `options[:headers]`, which
  # both the streaming and httpc request paths already forward.
  # Best-effort: a spec-compliant server (Ouroboros) returns a session id and
  # the call only works with it; a sessionless server or test stub returns no
  # session id, so we proceed exactly as before. Either way `execute_parent_
  # call` continues — the handshake never turns a working call into a failure.
  defp ensure_mcp_session(url, options) do
    cond do
      not Keyword.get(options, :mcp_session, false) ->
        {:ok, options}

      has_header?(options, "mcp-session-id") ->
        {:ok, options}

      true ->
        with {:ok, session_id} <- mcp_initialize(url, options),
             :ok <- mcp_initialized(url, session_id, options) do
          session_headers = [
            {"mcp-session-id", session_id},
            {"mcp-protocol-version", @protocol_version}
          ]

          {:ok,
           Keyword.put(options, :headers, session_headers ++ Keyword.get(options, :headers, []))}
        else
          _no_session -> {:ok, options}
        end
    end
  end

  defp mcp_initialize(url, options) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => "ourocode-init",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "ourocode", "version" => "0.1.0"}
      }
    }

    case mcp_post(url, payload, [], options) do
      {:ok, status, headers, _body} when status in 200..299 ->
        case header_value(headers, "mcp-session-id") do
          nil -> {:error, :mcp_session_id_missing}
          id -> {:ok, id}
        end

      {:ok, status, _headers, body} ->
        {:error, {:mcp_initialize_failed, status, body}}

      {:error, reason} ->
        {:error, {:mcp_initialize_request_failed, reason}}
    end
  end

  defp mcp_initialized(url, session_id, options) do
    payload = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{}
    }

    extra = [
      {~c"mcp-session-id", String.to_charlist(session_id)},
      {~c"mcp-protocol-version", String.to_charlist(@protocol_version)}
    ]

    case mcp_post(url, payload, extra, options) do
      {:ok, status, _headers, _body} when status in 200..299 -> :ok
      {:ok, status, _headers, body} -> {:error, {:mcp_initialized_failed, status, body}}
      {:error, reason} -> {:error, {:mcp_initialized_request_failed, reason}}
    end
  end

  defp mcp_post(url, payload, extra_headers, options) do
    timeout = Keyword.get(options, :timeout, @default_timeout)

    headers =
      [{~c"accept", ~c"application/json, text/event-stream"}] ++ extra_headers

    body = payload |> Json.encode!() |> IO.iodata_to_binary() |> String.to_charlist()

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", body},
           [timeout: timeout, connect_timeout: timeout],
           [body_format: :binary]
         ) do
      {:ok, {{_, status, _reason}, resp_headers, resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp has_header?(options, name) do
    options
    |> Keyword.get(:headers, [])
    |> Enum.any?(fn {k, _v} -> String.downcase(to_string(k)) == name end)
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == name, do: to_string(v)
    end)
  end

  defp post_json(url, request, options) do
    case stream_post_json(url, request, options) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:missing_event_stream_content_type, _status, _headers, _body}} ->
        httpc_post_json(url, request, options)

      {:error, {:unsupported_scheme, _scheme}} ->
        httpc_post_json(url, request, options)

      {:error, {:invalid_url, _url}} = error ->
        error

      {:error, _reason} = error ->
        error
    end
  end

  defp httpc_post_json(url, request, options) do
    timeout = Keyword.get(options, :timeout, @default_timeout)

    headers =
      [
        {~c"accept", ~c"application/json, text/event-stream"}
      ] ++ charlist_headers(Keyword.get(options, :headers, []))

    body = request |> Json.encode!() |> IO.iodata_to_binary() |> String.to_charlist()
    http_options = [timeout: timeout, connect_timeout: timeout]
    request_options = [body_format: :binary]

    :httpc.request(
      :post,
      {String.to_charlist(url), headers, ~c"application/json", body},
      http_options,
      request_options
    )
  end

  defp stream_post_json(url, request, options) do
    timeout = Keyword.get(options, :timeout, @default_timeout)

    with {:ok, uri} <- parse_http_url(url),
         {:ok, socket} <- connect(uri, timeout),
         :ok <- send_stream_request(socket, uri, request, options),
         {:ok, status, headers, body_rest} <- recv_response_headers(socket, "", timeout) do
      headers = normalize_headers(headers)

      if event_stream?(headers) do
        stream_sse_body(socket, status, headers, body_rest, options, request, timeout)
      else
        case recv_remaining_http_body(socket, headers, body_rest, timeout) do
          {:ok, body} ->
            :gen_tcp.close(socket)
            {:ok, {{~c"HTTP/1.1", status, ~c"OK"}, headers, body}}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, reason}
        end
      end
    end
  end

  defp parse_http_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "http" -> {:error, {:unsupported_scheme, uri.scheme}}
      is_nil(uri.host) -> {:error, {:invalid_url, url}}
      true -> {:ok, uri}
    end
  end

  defp connect(uri, timeout) do
    :gen_tcp.connect(
      String.to_charlist(uri.host),
      uri.port || 80,
      [:binary, packet: :raw, active: false],
      timeout
    )
  end

  defp send_stream_request(socket, uri, request, options) do
    body = request |> Json.encode!() |> IO.iodata_to_binary()

    request_headers =
      [
        {"host", host_header(uri)},
        {"accept", "application/json, text/event-stream"},
        {"content-type", "application/json"},
        {"content-length", byte_size(body)},
        {"connection", "close"}
      ] ++ Keyword.get(options, :headers, [])

    data = [
      "POST ",
      request_target(uri),
      " HTTP/1.1\r\n",
      Enum.map(request_headers, fn {key, value} ->
        [to_string(key), ": ", to_string(value), "\r\n"]
      end),
      "\r\n",
      body
    ]

    case :gen_tcp.send(socket, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:request_send_failed, reason}}
    end
  end

  defp host_header(uri) do
    if uri.port && uri.port != 80 do
      "#{uri.host}:#{uri.port}"
    else
      uri.host
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

  defp recv_response_headers(socket, acc, timeout) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers_blob, body_rest] when body_rest != nil and headers_blob != acc ->
        with {:ok, status, headers} <- parse_response_headers(headers_blob) do
          {:ok, status, headers, body_rest}
        end

      _ ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, chunk} -> recv_response_headers(socket, acc <> chunk, timeout)
          {:error, reason} -> {:error, {:response_header_recv_failed, reason}}
        end
    end
  end

  defp parse_response_headers(headers_blob) do
    [status_line | header_lines] = String.split(headers_blob, "\r\n")

    with [_, status_text | _] <- String.split(status_line, " ", parts: 3),
         {status, ""} <- Integer.parse(status_text) do
      headers =
        Enum.flat_map(header_lines, fn line ->
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

  defp recv_remaining_http_body(socket, headers, body_rest, timeout) do
    case content_length(headers) do
      nil ->
        recv_until_closed(socket, body_rest, timeout)

      length ->
        recv_until_length(socket, body_rest, length, timeout)
    end
  end

  defp recv_until_length(_socket, body, length, _timeout) when byte_size(body) >= length do
    {:ok, binary_part(body, 0, length)}
  end

  defp recv_until_length(socket, body, length, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, chunk} -> recv_until_length(socket, body <> chunk, length, timeout)
      {:error, reason} -> {:error, {:body_recv_failed, reason}}
    end
  end

  defp recv_until_closed(socket, body, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, chunk} -> recv_until_closed(socket, body <> chunk, timeout)
      {:error, :closed} -> {:ok, body}
      {:error, reason} -> {:error, {:body_recv_failed, reason}}
    end
  end

  defp stream_sse_body(socket, status, headers, body_rest, options, request, timeout) do
    context = normalizer_context(options, request, Keyword.get(options, :event_seq, 1) + 1)

    state = %{
      buffer: body_rest,
      events: [],
      next_event_seq: context.event_seq,
      response: nil,
      content_length: content_length(headers),
      bytes_seen: byte_size(body_rest)
    }

    case drain_sse_stream(socket, status, headers, context, options, state, timeout) do
      {:ok, response} ->
        :gen_tcp.close(socket)
        body = response |> Json.encode!() |> IO.iodata_to_binary()
        streamed_headers = [{"x-ourocode-streamed-sse", "true"} | headers]
        {:ok, {{~c"HTTP/1.1", status, ~c"OK"}, streamed_headers, body}}

      {:error, reason} ->
        :gen_tcp.close(socket)
        {:error, reason}
    end
  end

  defp drain_sse_stream(socket, status, headers, context, options, state, timeout) do
    state = emit_complete_sse_frames(status, headers, context, options, state)

    cond do
      state.content_length && state.bytes_seen >= state.content_length ->
        {:ok, state.response || response_from_sse_events(Enum.reverse(state.events))}

      true ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, chunk} ->
            next_state = %{
              state
              | buffer: state.buffer <> chunk,
                bytes_seen: state.bytes_seen + byte_size(chunk)
            }

            drain_sse_stream(socket, status, headers, context, options, next_state, timeout)

          {:error, :closed} ->
            {:ok, state.response || response_from_sse_events(Enum.reverse(state.events))}

          {:error, reason} ->
            {:error, {:sse_recv_failed, reason}}
        end
    end
  end

  defp emit_complete_sse_frames(status, headers, context, options, state) do
    case parse_complete_sse_frames_with_raw(state.buffer) do
      {:ok, [], rest} ->
        %{state | buffer: rest}

      {:ok, parsed_events, rest} ->
        Enum.reduce(parsed_events, %{state | buffer: rest}, fn {parsed_event, raw_frame}, acc ->
          event_context =
            context
            |> Map.put(:event_seq, acc.next_event_seq)
            |> Map.put(:status, status)
            |> Map.put(:headers, headers)

          {:ok, lifecycle_events} =
            LifecycleNormalizer.normalize_sse_events([parsed_event], event_context)

          response_record =
            build_raw_response_event_record(
              [
                url: Keyword.get(options, :url),
                status: status,
                headers: headers,
                raw_payload: raw_frame
              ],
              raw_response_event_payload(parsed_event),
              event_context
            )

          lifecycle_events
          |> Enum.map(&annotate_raw_response_event(&1, response_record))
          |> Enum.each(&emit_event(options, &1))

          %{
            acc
            | events: [parsed_event | acc.events],
              next_event_seq: acc.next_event_seq + length(lifecycle_events),
              response: response_from_parsed_events([parsed_event]) || acc.response
          }
        end)

      {:error, reason} ->
        failed_context =
          context
          |> Map.put(:event_seq, state.next_event_seq)
          |> Map.put(:status, status)
          |> Map.put(:headers, headers)

        response_record =
          build_raw_response_event_record(
            [
              url: Keyword.get(options, :url),
              status: status,
              headers: headers,
              raw_payload: state.buffer
            ],
            %{},
            failed_context
          )

        emit_event(
          options,
          failed_context
          |> LifecycleNormalizer.failed(reason)
          |> annotate_raw_response_event(response_record)
        )

        %{state | buffer: "", next_event_seq: state.next_event_seq + 1}
    end
  end

  defp parse_complete_sse_frames_with_raw(buffer) do
    {frames, rest} = Ourocode.MCP.Transport.SSE.Parser.split_complete_frames(buffer)

    frames
    |> Enum.reduce_while({:ok, []}, fn frame, {:ok, acc} ->
      case Ourocode.MCP.Transport.SSE.Parser.parse_frame(frame) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, event} -> {:cont, {:ok, [{event, frame} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events), rest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp raw_response_event_payload(%{"data" => data} = parsed_event) when is_map(data) do
    data
    |> Map.put(:sse_event_id, Map.get(parsed_event, "id"))
    |> Map.put(:sse_event_type, Map.get(parsed_event, "event"))
  end

  defp raw_response_event_payload(%{"metadata" => metadata} = parsed_event)
       when is_map(metadata) do
    metadata
    |> Map.put(:sse_event_id, Map.get(parsed_event, "id"))
    |> Map.put(:sse_event_type, Map.get(parsed_event, "event"))
  end

  defp raw_response_event_payload(parsed_event) when is_map(parsed_event), do: parsed_event

  defp response_from_parsed_events(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"data" => %{"id" => _id} = data} -> data
      _event -> nil
    end)
  end

  defp content_length(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == "content-length" do
        case Integer.parse(to_string(value)) do
          {length, ""} -> length
          _ -> nil
        end
      end
    end)
  end

  defp decode_response(status, headers, body) when status in 200..299 do
    cond do
      streamed_sse?(headers) ->
        Json.decode(body)

      event_stream?(headers) ->
        with {:ok, events} <- LifecycleNormalizer.parse_sse(body) do
          {:ok, response_from_sse_events(events)}
        end

      true ->
        Json.decode(body)
    end
  end

  defp decode_response(status, _headers, body) do
    {:error, {:http_error, status, body}}
  end

  defp response_from_sse_events(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"data" => %{"id" => _id} = data} -> data
      _event -> nil
    end)
    |> case do
      nil -> %{"events" => Enum.map(events, &Map.fetch!(&1, "data"))}
      response -> response
    end
  end

  defp build_result(options, status, headers, response) do
    %ParentCallResult{
      parent_call_id: Keyword.get(options, :parent_call_id, response["id"] || "parent-http-call"),
      runtime_source: Keyword.get(options, :runtime_source, "synthetic"),
      transport: :streamable_http,
      external_ids: Keyword.get(options, :external_ids, %{}),
      response: response,
      status: status,
      headers: headers,
      received_at: System.monotonic_time(:millisecond)
    }
  end

  defp emit_started(options, request) do
    context = normalizer_context(options, request, Keyword.get(options, :event_seq, 1))

    event =
      context
      |> LifecycleNormalizer.started()
      |> Map.put(:raw_event, build_raw_request_event_record(options, request, context))

    emit_event(options, event)
  end

  defp emit_response_events(options, request, status, headers, body) do
    context = normalizer_context(options, request, Keyword.get(options, :event_seq, 1) + 1)

    case LifecycleNormalizer.normalize_body(status, headers, body, context) do
      {:ok, events} ->
        response_record =
          build_raw_response_event_record(
            [
              url: Keyword.get(options, :url),
              status: status,
              headers: headers,
              raw_payload: body
            ],
            %{},
            context
          )

        events
        |> Enum.map(&annotate_raw_response_event(&1, response_record))
        |> Enum.each(&emit_event(options, &1))

      {:error, reason} ->
        response_record =
          build_raw_response_event_record(
            [
              url: Keyword.get(options, :url),
              status: status,
              headers: headers,
              raw_payload: body
            ],
            %{},
            context
          )

        emit_event(
          options,
          context
          |> LifecycleNormalizer.failed(reason)
          |> annotate_raw_response_event(response_record)
        )
    end
  end

  defp emit_event(options, event) do
    persist_event(Keyword.get(options, :journal_path), event)

    case Keyword.get(options, :subscriber) do
      pid when is_pid(pid) ->
        send(pid, {:ourocode_event, event})

      _ ->
        :ok
    end

    :ok
  end

  defp persist_event(nil, _event), do: :ok

  defp persist_event(path, event) when is_binary(path) do
    Journal.append!(path, canonical_journal_event(event))
  end

  @doc false
  @spec canonical_journal_event(Ourocode.MCP.LifecycleEvent.t() | map()) :: map()
  def canonical_journal_event(%Ourocode.MCP.LifecycleEvent{} = event) do
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

  defp normalizer_context(options, request, event_seq) do
    request_id = request["id"] || request[:id]

    %{
      event_seq: event_seq,
      parent_call_id:
        Keyword.get(
          options,
          :parent_call_id,
          normalize_request_id(request_id) || "parent-http-call"
        ),
      runtime_source: Keyword.get(options, :runtime_source, "synthetic"),
      external_ids: Keyword.get(options, :external_ids, %{}),
      request_id: normalize_request_id(request_id),
      method: request["method"] || request[:method],
      params: request["params"] || request[:params],
      occurred_at_ms: System.system_time(:millisecond)
    }
  end

  @doc false
  @spec build_raw_request_event_record(keyword(), map(), map()) :: map()
  def build_raw_request_event_record(options, request, context)
      when is_list(options) and is_map(request) and is_map(context) do
    raw_payload = request |> Json.encode!() |> IO.iodata_to_binary()
    request_id = Map.get(context, :request_id)
    timestamp_ms = Map.fetch!(context, :occurred_at_ms)

    %{
      transport: :streamable_http,
      transport_type: :streamable_http,
      stream_direction: :outbound,
      correlation_id: request_id || Map.fetch!(context, :parent_call_id),
      request_id: request_id,
      parent_call_id: Map.fetch!(context, :parent_call_id),
      method: Map.get(context, :method),
      url: Keyword.get(options, :url),
      timestamp_ms: timestamp_ms,
      sent_at_ms: timestamp_ms,
      raw_payload_ref: raw_payload_ref(raw_payload),
      raw_payload_size_bytes: byte_size(raw_payload)
    }
  end

  @doc false
  @spec build_raw_response_event_record(keyword(), map(), map()) :: map()
  def build_raw_response_event_record(options, raw_event, context)
      when is_list(options) and is_map(raw_event) and is_map(context) do
    raw_payload = Keyword.get(options, :raw_payload, "")
    timestamp_ms = Map.get(context, :occurred_at_ms, System.system_time(:millisecond))
    request_id = response_request_id(raw_event, context)

    Map.merge(raw_event, %{
      transport: :streamable_http,
      transport_type: :streamable_http,
      stream_direction: :inbound,
      correlation_id: request_id || Map.fetch!(context, :parent_call_id),
      request_id: request_id,
      parent_call_id: Map.fetch!(context, :parent_call_id),
      status: Keyword.get(options, :status, Map.get(context, :status)),
      headers: Keyword.get(options, :headers, Map.get(context, :headers)),
      url: Keyword.get(options, :url),
      timestamp_ms: timestamp_ms,
      received_at_ms: timestamp_ms,
      raw_payload_ref: raw_payload_ref(raw_payload),
      raw_payload_size_bytes: byte_size(raw_payload)
    })
    |> Map.delete(:raw_payload)
    |> Map.delete("raw_payload")
  end

  defp annotate_raw_response_event(%Ourocode.MCP.LifecycleEvent{} = event, response_record) do
    raw_event =
      case event.raw_event do
        raw_event when is_map(raw_event) -> Map.merge(raw_event, response_record)
        _ -> response_record
      end

    %{event | raw_event: raw_event}
  end

  defp response_request_id(raw_event, context) do
    cond do
      is_binary(Map.get(raw_event, "id")) -> Map.get(raw_event, "id")
      is_integer(Map.get(raw_event, "id")) -> to_string(Map.get(raw_event, "id"))
      is_binary(Map.get(raw_event, :request_id)) -> Map.get(raw_event, :request_id)
      is_integer(Map.get(raw_event, :request_id)) -> to_string(Map.get(raw_event, :request_id))
      true -> Map.get(context, :request_id)
    end
  end

  defp normalize_request_id(nil), do: nil
  defp normalize_request_id(request_id), do: to_string(request_id)

  defp raw_payload_ref(payload) when is_binary(payload) do
    "sha256:" <>
      (:crypto.hash(:sha256, payload)
       |> Base.encode16(case: :lower))
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp charlist_headers(headers) do
    Enum.map(headers, fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end

  defp event_stream?(headers) do
    Enum.any?(headers, fn {key, value} ->
      String.downcase(key) == "content-type" and
        value |> String.downcase() |> String.contains?("text/event-stream")
    end)
  end

  defp streamed_sse?(headers) do
    Enum.any?(headers, fn {key, value} ->
      String.downcase(to_string(key)) == "x-ourocode-streamed-sse" and
        String.downcase(to_string(value)) == "true"
    end)
  end

  defp next_event_seq(options), do: Keyword.get(options, :event_seq, 0) + 1

  defp default_child_id(opts) do
    {__MODULE__, Keyword.get(opts, :parent_call_id), Keyword.get(opts, :url)}
  end
end
