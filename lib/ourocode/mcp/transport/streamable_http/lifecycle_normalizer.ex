defmodule Ourocode.MCP.Transport.StreamableHTTP.LifecycleNormalizer do
  @moduledoc """
  Normalizes streamable HTTP MCP parent call lifecycle data.

  Streamable HTTP can return a single JSON-RPC response or a text/event-stream
  body containing JSON-RPC notifications and responses. This module converts
  both forms into typed `Ourocode.MCP.LifecycleEvent` structs.
  """

  alias Ourocode.Json
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.RuntimeEventParser

  @type context :: %{
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:external_ids) => map(),
          optional(:event_seq) => non_neg_integer(),
          optional(:request_id) => String.t(),
          optional(:method) => String.t(),
          optional(:params) => map() | list() | nil,
          optional(:occurred_at_ms) => integer(),
          optional(:status) => non_neg_integer(),
          optional(:headers) => [{String.t(), String.t()}]
        }

  @spec started(context()) :: LifecycleEvent.t()
  def started(context) do
    build(:parent_call_started, context, %{
      request_id: Map.get(context, :request_id),
      method: Map.get(context, :method),
      params: Map.get(context, :params)
    })
  end

  @spec failed(context(), term()) :: LifecycleEvent.t()
  def failed(context, reason) do
    build(:parent_call_failed, context, %{
      request_id: Map.get(context, :request_id),
      method: Map.get(context, :method),
      error: reason
    })
  end

  @spec normalize_body(non_neg_integer(), [{String.t(), String.t()}], String.t(), context()) ::
          {:ok, [LifecycleEvent.t()]} | {:error, term()}
  def normalize_body(status, headers, body, context) when is_binary(body) do
    context =
      context
      |> Map.put(:status, status)
      |> Map.put(:headers, headers)

    if event_stream?(headers) do
      normalize_sse_body(body, context)
    else
      with {:ok, decoded} <- Json.decode(body) do
        {:ok, [json_rpc_event(decoded, merge_event_external_ids(context, decoded))]}
      end
    end
  end

  @spec parse_sse(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse_sse(body) when is_binary(body) do
    body
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.reduce_while({:ok, []}, fn frame, {:ok, acc} ->
      case parse_sse_frame(frame) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp normalize_sse_body(body, context) do
    with {:ok, events} <- parse_sse(body) do
      normalize_sse_events(events, context)
    end
  end

  @spec normalize_sse_events([map()], context()) :: {:ok, [LifecycleEvent.t()]}
  def normalize_sse_events(events, context) when is_list(events) and is_map(context) do
    base_seq = Map.get(context, :event_seq, 1) || 1

    lifecycle_events =
      events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} ->
        data = Map.fetch!(event, "data")

        event_context =
          context
          |> Map.put(:event_seq, base_seq + index)
          |> merge_event_external_ids(event)

        json_rpc_event(data, event_context)
      end)

    {:ok, lifecycle_events}
  end

  defp parse_sse_frame(frame) do
    fields =
      frame
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.trim_leading/1)
      |> Enum.reject(&String.starts_with?(&1, ":"))
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            Map.update(
              acc,
              String.trim(key),
              [String.trim_leading(value)],
              &[
                String.trim_leading(value) | &1
              ]
            )

          [key] ->
            Map.put_new(acc, String.trim(key), [""])
        end
      end)

    case fields do
      %{"data" => data_lines} ->
        data = data_lines |> Enum.reverse() |> Enum.join("\n")

        with {:ok, decoded} <- Json.decode(data) do
          {:ok,
           fields
           |> Map.put("data", decoded)
           |> Map.update("event", "message", fn values ->
             values |> List.first() |> to_string()
           end)
           |> Map.update("id", nil, fn values -> values |> List.first() |> to_string() end)}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp json_rpc_event(%{"id" => request_id, "result" => result} = decoded, context) do
    case lifecycle_response_event(decoded, context) do
      {:ok, event} ->
        event

      :error ->
        build(:parent_call_result, context, %{
          request_id: to_string(request_id),
          result: result,
          raw_event: decoded
        })
    end
  end

  defp json_rpc_event(%{"id" => request_id, "error" => error} = decoded, context) do
    case lifecycle_error_response_event(decoded, context) do
      {:ok, event} ->
        event

      :error ->
        build(:parent_call_failed, context, %{
          request_id: to_string(request_id),
          error: error,
          raw_event: decoded
        })
    end
  end

  defp json_rpc_event(%{"method" => _method} = decoded, context) do
    case lifecycle_record_event(decoded, context) do
      {:ok, event} ->
        event

      :error ->
        build(:parent_call_event, context, %{
          notification: decoded,
          raw_event: decoded
        })
    end
  end

  defp json_rpc_event(decoded, context) do
    case lifecycle_record_event(decoded, context) do
      {:ok, event} ->
        event

      :error ->
        build(:parent_call_unmatched_result, context, %{
          result: decoded,
          raw_event: decoded
        })
    end
  end

  defp merge_event_external_ids(context, decoded) do
    external_ids =
      context
      |> Map.fetch!(:external_ids)
      |> Map.merge(source_external_ids(decoded))
      |> Map.merge(RuntimeEventParser.extract_external_ids(decoded))

    Map.put(context, :external_ids, external_ids)
  end

  defp source_external_ids(%{"external_ids" => external_ids}) when is_map(external_ids) do
    external_ids
  end

  defp source_external_ids(%{external_ids: external_ids}) when is_map(external_ids) do
    external_ids
  end

  defp source_external_ids(_decoded), do: %{}

  defp lifecycle_record_event(decoded, context) do
    case lifecycle_record_type(decoded) do
      {:ok, type} ->
        {:ok,
         build(type, merge_event_external_ids(context, decoded), lifecycle_record_attrs(decoded))}

      :error ->
        :error
    end
  end

  defp lifecycle_response_event(%{"id" => request_id, "result" => result} = decoded, context)
       when is_map(result) do
    with {:ok, type} <- lifecycle_record_type(result),
         true <- lifecycle_result_envelope?(result) do
      attrs =
        result
        |> lifecycle_record_attrs()
        |> Map.put_new(:request_id, to_string(request_id))
        |> Map.put(:raw_event, decoded)

      event_context =
        context
        |> merge_event_external_ids(decoded)
        |> merge_event_external_ids(result)

      {:ok, build(type, event_context, attrs)}
    else
      _not_a_lifecycle_envelope ->
        lifecycle_record_event(decoded, context)
    end
  end

  defp lifecycle_response_event(decoded, context), do: lifecycle_record_event(decoded, context)

  # A JSON-RPC `result` is only treated as a re-serialized lifecycle event when
  # it carries the lifecycle outcome itself (`result` or `error`). A `result`
  # that merely has a `type`/`payload` without an inner outcome is an opaque
  # parent-call result and must be preserved verbatim so stdio/SSE/streamable
  # HTTP normalize symmetrically before journaling.
  defp lifecycle_result_envelope?(result) do
    Map.has_key?(result, "result") or Map.has_key?(result, "error")
  end

  defp lifecycle_error_response_event(%{"id" => request_id, "error" => error} = decoded, context)
       when is_map(error) do
    error
    |> lifecycle_error_candidates()
    |> Enum.find_value(fn
      candidate when is_map(candidate) ->
        case lifecycle_record_type(candidate) do
          {:ok, type} ->
            attrs =
              candidate
              |> lifecycle_record_attrs()
              |> Map.put_new(:request_id, to_string(request_id))
              |> Map.put_new(:error, error)
              |> Map.put_new(:error_details, error)
              |> Map.put(:raw_event, decoded)

            event_context =
              context
              |> merge_event_external_ids(decoded)
              |> merge_event_external_ids(error)
              |> merge_event_external_ids(candidate)

            {:ok, build(type, event_context, attrs)}

          :error ->
            nil
        end

      _candidate ->
        nil
    end)
    |> case do
      nil -> lifecycle_record_event(decoded, context)
      {:ok, event} -> {:ok, event}
    end
  end

  defp lifecycle_error_response_event(decoded, context), do: lifecycle_record_event(decoded, context)

  defp lifecycle_error_candidates(error) do
    data = Map.get(error, "data")

    data_candidates =
      if is_map(data) do
        [Map.get(data, "lifecycle_event"), Map.get(data, "event"), data]
      else
        [data]
      end

    data_candidates ++ [error]
  end

  @lifecycle_types %{
    "parent_call_event" => :parent_call_event,
    "parent_call_failed" => :parent_call_failed,
    "parent_call_result" => :parent_call_result,
    "parent_call_started" => :parent_call_started,
    "parent_call_unmatched_result" => :parent_call_unmatched_result,
    "parent_call_write_failed" => :parent_call_write_failed,
    "transport_cleanup" => :transport_cleanup,
    "transport_decode_failed" => :transport_decode_failed,
    "transport_exited" => :transport_exited,
    "transport_failed" => :transport_failed,
    "transport_metadata" => :transport_metadata,
    "transport_started" => :transport_started
  }

  defp lifecycle_record_type(decoded) do
    decoded
    |> Map.get("type", Map.get(decoded, "event_type"))
    |> case do
      type when is_binary(type) -> Map.fetch(@lifecycle_types, String.trim(type))
      _type -> :error
    end
  end

  defp lifecycle_record_attrs(decoded) do
    decoded
    |> Map.take([
      "call_id",
      "request_id",
      "method",
      "params",
      "payload",
      "result",
      "error",
      "error_details",
      "notification",
      "status",
      "headers",
      "cleanup_reason",
      "released_resources",
      "stale_cleanup_timeout_ms"
    ])
    |> Enum.reduce(%{raw_event: decoded}, fn {key, value}, acc ->
      Map.put(acc, String.to_existing_atom(key), value)
    end)
  end

  defp build(type, context, attrs) do
    LifecycleEvent.new(
      type,
      Map.merge(
        %{
          event_seq: Map.get(context, :event_seq, 1),
          transport: :streamable_http,
          parent_call_id: Map.fetch!(context, :parent_call_id),
          runtime_source: Map.fetch!(context, :runtime_source),
          external_ids: Map.fetch!(context, :external_ids),
          occurred_at_ms: Map.get(context, :occurred_at_ms, System.system_time(:millisecond)),
          status: Map.get(context, :status),
          headers: Map.get(context, :headers)
        },
        attrs
      )
    )
  end

  defp event_stream?(headers) do
    Enum.any?(headers, fn {key, value} ->
      String.downcase(key) == "content-type" and
        value |> String.downcase() |> String.contains?("text/event-stream")
    end)
  end
end
