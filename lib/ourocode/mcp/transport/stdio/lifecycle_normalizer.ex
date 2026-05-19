defmodule Ourocode.MCP.Transport.Stdio.LifecycleNormalizer do
  @moduledoc """
  Normalizes parsed stdio JSONL MCP protocol messages into lifecycle events.

  The stdio transport first decodes stdout lines into
  `Ourocode.MCP.Transport.RawProtocolMessage` structs. This module converts
  those typed protocol messages into the same journal-ready lifecycle schema
  used by the other MCP transports.
  """

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.RuntimeEventParser

  @type context :: %{
          required(:event_seq) => non_neg_integer(),
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:external_ids) => map(),
          optional(:occurred_at_ms) => integer()
        }

  @type raw_protocol_message :: Ourocode.MCP.Transport.RawProtocolMessage.t()

  @doc """
  Normalizes a parsed JSON-RPC request, notification, or unknown object.

  Responses tied to active parent calls need caller reply side effects, so the
  owning stdio transport completes those separately before emitting the final
  lifecycle event.
  """
  @spec normalize_protocol_message(raw_protocol_message(), context()) :: LifecycleEvent.t()
  def normalize_protocol_message(%{raw: decoded} = message, context) do
    case lifecycle_record_event(decoded, context) do
      {:ok, event} -> event
      :error -> normalize_json_rpc_protocol_message(message, context)
    end
  end

  defp normalize_json_rpc_protocol_message(%{kind: :request, raw: decoded} = message, context) do
    attrs =
      %{
        notification: decoded,
        payload: notification_payload(decoded),
        raw_event: decoded
      }
      |> maybe_put(:request_id, normalize_request_id(message.id))
      |> maybe_put(:method, message.method)
      |> maybe_put(:params, message.params)

    build(:parent_call_event, merge_event_external_ids(context, decoded), attrs)
  end

  defp normalize_json_rpc_protocol_message(%{kind: :notification, raw: decoded}, context) do
    build(:parent_call_event, merge_event_external_ids(context, decoded), %{
      notification: decoded,
      payload: notification_payload(decoded),
      raw_event: decoded
    })
  end

  defp normalize_json_rpc_protocol_message(%{raw: decoded}, context) do
    build(:parent_call_unmatched_result, merge_event_external_ids(context, decoded), %{
      result: decoded,
      raw_event: decoded
    })
  end

  @doc """
  Builds a normalized stdio parent call response event.
  """
  @spec parent_call_response(map(), {:ok, term()} | {:error, term()}, context(), map()) ::
          LifecycleEvent.t()
  def parent_call_response(decoded, {:ok, result}, context, attrs) do
    build(
      :parent_call_result,
      merge_event_external_ids(context, decoded),
      Map.merge(
        %{
          payload: result,
          result: result,
          raw_event: decoded
        },
        attrs
      )
    )
  end

  def parent_call_response(decoded, {:error, error}, context, attrs) do
    build(
      :parent_call_failed,
      merge_event_external_ids(context, decoded),
      Map.merge(
        %{
          error: error,
          raw_event: decoded
        },
        attrs
      )
    )
  end

  defp build(type, context, attrs) do
    LifecycleEvent.new(
      type,
      Map.merge(
        %{
          event_seq: Map.fetch!(context, :event_seq),
          transport: :stdio,
          parent_call_id: Map.fetch!(context, :parent_call_id),
          runtime_source: Map.fetch!(context, :runtime_source),
          external_ids: Map.fetch!(context, :external_ids),
          occurred_at_ms: Map.get(context, :occurred_at_ms, System.system_time(:millisecond))
        },
        attrs
      )
    )
  end

  defp merge_event_external_ids(context, payload) do
    external_ids =
      context
      |> Map.fetch!(:external_ids)
      |> Map.merge(source_external_ids(payload))
      |> Map.merge(RuntimeEventParser.extract_external_ids(payload))

    Map.put(context, :external_ids, external_ids)
  end

  defp source_external_ids(%{"external_ids" => external_ids}) when is_map(external_ids) do
    external_ids
  end

  defp source_external_ids(%{external_ids: external_ids}) when is_map(external_ids) do
    external_ids
  end

  defp source_external_ids(_payload), do: %{}

  defp notification_payload(%{"params" => params}) when is_map(params), do: params
  defp notification_payload(%{"params" => params}) when is_list(params), do: params
  defp notification_payload(decoded), do: decoded

  defp lifecycle_record_event(decoded, context) do
    case lifecycle_record_type(decoded) do
      {:ok, type} ->
        {:ok,
         build(type, merge_event_external_ids(context, decoded), lifecycle_record_attrs(decoded))}

      :error ->
        :error
    end
  end

  @lifecycle_types %{
    "parent_call_event" => :parent_call_event,
    "parent_call_failed" => :parent_call_failed,
    "parent_call_result" => :parent_call_result,
    "parent_call_started" => :parent_call_started,
    "parent_call_unmatched_result" => :parent_call_unmatched_result,
    "parent_call_write_failed" => :parent_call_write_failed,
    "hook_started" => :hook_started,
    "hook_progress" => :hook_progress,
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
      "hook_id",
      "request_id",
      "method",
      "params",
      "payload",
      "progress_state",
      "ordering_metadata",
      "source",
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

  defp normalize_request_id(nil), do: nil
  defp normalize_request_id(request_id), do: to_string(request_id)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
