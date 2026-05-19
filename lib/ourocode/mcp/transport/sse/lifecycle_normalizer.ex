defmodule Ourocode.MCP.Transport.SSE.LifecycleNormalizer do
  @moduledoc """
  Normalizes parsed SSE MCP messages into journal-ready lifecycle events.

  `Ourocode.MCP.Transport.SSE.Parser` owns byte and frame parsing. This module
  owns the transport-specific conversion from parsed SSE fields into the shared
  `Ourocode.MCP.LifecycleEvent` shape used by panes, journals, and replay.
  """

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.RuntimeEventParser

  @type context :: %{
          required(:event_seq) => non_neg_integer(),
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:external_ids) => map(),
          optional(:occurred_at_ms) => integer(),
          optional(:status) => non_neg_integer(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:method) => String.t(),
          optional(:params) => map() | list() | nil
        }

  @doc """
  Converts one parsed SSE event into the shared lifecycle event shape.
  """
  @spec normalize_parsed_event(map(), context()) :: LifecycleEvent.t()
  def normalize_parsed_event(
        %{"data" => %{"id" => request_id, "result" => result}} = event,
        context
      ) do
    request_id = to_string(request_id)

    build(:parent_call_result, merge_event_external_ids(context, event), %{
      call_id: request_id,
      request_id: request_id,
      method: Map.get(context, :method),
      params: Map.get(context, :params),
      payload: result,
      result: result,
      raw_event: event
    })
  end

  def normalize_parsed_event(
        %{"data" => %{"id" => request_id, "error" => error}} = event,
        context
      ) do
    request_id = to_string(request_id)

    build(:parent_call_failed, merge_event_external_ids(context, event), %{
      call_id: request_id,
      request_id: request_id,
      method: Map.get(context, :method),
      params: Map.get(context, :params),
      error: error,
      error_details: error,
      raw_event: event
    })
  end

  def normalize_parsed_event(%{"data" => %{"method" => _method} = decoded} = event, context) do
    build(:parent_call_event, merge_event_external_ids(context, event), %{
      notification: decoded,
      payload: notification_payload(decoded),
      raw_event: event
    })
  end

  def normalize_parsed_event(%{"data" => decoded} = event, context) do
    build(:parent_call_unmatched_result, merge_event_external_ids(context, event), %{
      result: decoded,
      raw_event: event
    })
  end

  def normalize_parsed_event(%{"metadata" => metadata} = event, context) do
    build(:transport_metadata, merge_event_external_ids(context, event), %{
      payload: metadata,
      raw_event: event
    })
  end

  def normalize_parsed_event(event, context) when is_map(event) do
    build(:transport_decode_failed, merge_event_external_ids(context, event), %{
      error: {:invalid_sse_event, :missing_data_or_metadata},
      error_details: %{
        reason: :missing_data_or_metadata,
        required_any_of: ["data", "metadata"]
      },
      raw_event: event
    })
  end

  defp build(type, context, attrs) do
    LifecycleEvent.new(
      type,
      Map.merge(
        %{
          event_seq: Map.fetch!(context, :event_seq),
          transport: :sse,
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

  defp merge_event_external_ids(context, event) do
    external_ids =
      context
      |> Map.fetch!(:external_ids)
      |> Map.merge(source_external_ids(event))
      |> Map.merge(RuntimeEventParser.extract_external_ids(event))

    Map.put(context, :external_ids, external_ids)
  end

  defp source_external_ids(%{"external_ids" => external_ids}) when is_map(external_ids) do
    external_ids
  end

  defp source_external_ids(%{external_ids: external_ids}) when is_map(external_ids) do
    external_ids
  end

  defp source_external_ids(_event), do: %{}

  defp notification_payload(%{"params" => params}) when is_map(params), do: params
  defp notification_payload(%{"params" => params}) when is_list(params), do: params
  defp notification_payload(decoded), do: decoded
end
