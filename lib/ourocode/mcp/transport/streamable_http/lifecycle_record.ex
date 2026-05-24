defmodule Ourocode.MCP.Transport.StreamableHTTP.LifecycleRecord do
  @moduledoc """
  Classifies serialized streamable HTTP lifecycle records.

  The streamable HTTP normalizer accepts both raw JSON-RPC responses and
  previously serialized lifecycle event records. This module owns the pure
  record-shape rules so transport normalization can focus on context and event
  construction.
  """

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

  @attr_keys [
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
  ]

  @spec type(map()) :: {:ok, atom()} | :error
  def type(decoded) when is_map(decoded) do
    decoded
    |> Map.get("type", Map.get(decoded, "event_type"))
    |> case do
      type when is_binary(type) -> Map.fetch(@lifecycle_types, String.trim(type))
      _type -> :error
    end
  end

  @spec attrs(map()) :: map()
  def attrs(decoded) when is_map(decoded) do
    decoded
    |> Map.take(@attr_keys)
    |> Enum.reduce(%{raw_event: decoded}, fn {key, value}, acc ->
      Map.put(acc, String.to_existing_atom(key), value)
    end)
  end

  @doc """
  Returns true when a JSON-RPC `result` carries a serialized lifecycle outcome.

  A map that merely has `type` and `payload` is still an opaque parent-call
  result; treating it as a lifecycle event would drop the original result shape.
  """
  @spec result_envelope?(map()) :: boolean()
  def result_envelope?(result) when is_map(result) do
    Map.has_key?(result, "result") or Map.has_key?(result, "error")
  end

  @spec error_candidates(map()) :: [term()]
  def error_candidates(error) when is_map(error) do
    data = Map.get(error, "data")

    data_candidates =
      if is_map(data) do
        [Map.get(data, "lifecycle_event"), Map.get(data, "event"), data]
      else
        [data]
      end

    data_candidates ++ [error]
  end
end
