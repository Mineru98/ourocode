defmodule Ourocode.MCP.Transport.StreamableHTTP.LifecycleEventBuilder do
  @moduledoc """
  Builds streamable HTTP lifecycle events from decoded JSON-RPC payloads.
  """

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.RuntimeEventParser
  alias Ourocode.MCP.Transport.StreamableHTTP.LifecycleRecord

  @spec started(map()) :: LifecycleEvent.t()
  def started(context) when is_map(context) do
    build(:parent_call_started, context, %{
      request_id: Map.get(context, :request_id),
      method: Map.get(context, :method),
      params: Map.get(context, :params)
    })
  end

  @spec failed(map(), term()) :: LifecycleEvent.t()
  def failed(context, reason) when is_map(context) do
    build(:parent_call_failed, context, %{
      request_id: Map.get(context, :request_id),
      method: Map.get(context, :method),
      error: reason
    })
  end

  @spec json_rpc_event(map(), map()) :: LifecycleEvent.t()
  def json_rpc_event(%{"id" => request_id, "result" => result} = decoded, context) do
    context = merge_external_ids(context, decoded)

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

  def json_rpc_event(%{"id" => request_id, "error" => error} = decoded, context) do
    context = merge_external_ids(context, decoded)

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

  def json_rpc_event(%{"method" => _method} = decoded, context) do
    context = merge_external_ids(context, decoded)

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

  def json_rpc_event(decoded, context) when is_map(decoded) and is_map(context) do
    context = merge_external_ids(context, decoded)

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

  defp lifecycle_record_event(decoded, context) do
    case LifecycleRecord.type(decoded) do
      {:ok, type} ->
        {:ok, build(type, merge_external_ids(context, decoded), LifecycleRecord.attrs(decoded))}

      :error ->
        :error
    end
  end

  defp lifecycle_response_event(%{"id" => request_id, "result" => result} = decoded, context)
       when is_map(result) do
    with {:ok, type} <- LifecycleRecord.type(result),
         true <- LifecycleRecord.result_envelope?(result) do
      attrs =
        result
        |> LifecycleRecord.attrs()
        |> Map.put_new(:request_id, to_string(request_id))
        |> Map.put(:raw_event, decoded)

      event_context =
        context
        |> merge_external_ids(decoded)
        |> merge_external_ids(result)

      {:ok, build(type, event_context, attrs)}
    else
      _not_a_lifecycle_envelope ->
        lifecycle_record_event(decoded, context)
    end
  end

  defp lifecycle_response_event(decoded, context), do: lifecycle_record_event(decoded, context)

  defp lifecycle_error_response_event(%{"id" => request_id, "error" => error} = decoded, context)
       when is_map(error) do
    error
    |> LifecycleRecord.error_candidates()
    |> Enum.find_value(fn
      candidate when is_map(candidate) ->
        case LifecycleRecord.type(candidate) do
          {:ok, type} ->
            attrs =
              candidate
              |> LifecycleRecord.attrs()
              |> Map.put_new(:request_id, to_string(request_id))
              |> Map.put_new(:error, error)
              |> Map.put_new(:error_details, error)
              |> Map.put(:raw_event, decoded)

            event_context =
              context
              |> merge_external_ids(decoded)
              |> merge_external_ids(error)
              |> merge_external_ids(candidate)

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

  defp lifecycle_error_response_event(decoded, context),
    do: lifecycle_record_event(decoded, context)

  @doc false
  @spec merge_external_ids(map(), map()) :: map()
  def merge_external_ids(context, decoded) do
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
end
