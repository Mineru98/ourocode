defmodule Ourocode.Journal.SourceTransportNormalizer.RawMetadata do
  @moduledoc """
  Preserves raw transport metadata on normalized lifecycle event records.
  """

  alias Ourocode.MCP.LifecycleEvent

  @raw_metadata_keys %{
    stdio: [
      :transport,
      :transport_type,
      :process_identifier,
      :session_identifier,
      :stream_direction,
      :timestamp_ms,
      :raw_payload_ref
    ],
    sse: [
      :transport,
      :transport_type,
      :endpoint_url,
      :connection_identifier,
      :session_identifier,
      :sse_event_id,
      :sse_event_id_present,
      :sse_event_type,
      :sse_event_type_present,
      :timestamp_ms,
      :received_at_ms,
      :raw_payload_ref,
      :raw_payload_stored?,
      :raw_payload_size_bytes
    ],
    streamable_http: [
      :transport,
      :transport_type,
      :stream_direction,
      :correlation_id,
      :request_id,
      :parent_call_id,
      :method,
      :status,
      :headers,
      :url,
      :timestamp_ms,
      :sent_at_ms,
      :received_at_ms,
      :raw_payload_ref,
      :raw_payload_size_bytes
    ]
  }

  @spec enrich([term()], term()) :: [term()]
  def enrich(events, source_event) when is_list(events) do
    metadata = raw_transport_metadata(source_event)

    if map_size(metadata) == 0 do
      events
    else
      Enum.map(events, &put_raw_event_metadata(&1, metadata))
    end
  end

  @spec source_transport(term()) :: atom() | term() | nil
  def source_transport(%{} = event),
    do: normalize_transport(Map.get(event, :transport) || Map.get(event, "transport"))

  def source_transport(_event), do: nil

  @spec normalize_transport(term()) :: atom() | term()
  def normalize_transport("stdio"), do: :stdio
  def normalize_transport("sse"), do: :sse
  def normalize_transport("streamable_http"), do: :streamable_http
  def normalize_transport(transport), do: transport

  @spec raw_transport_metadata(term()) :: map()
  def raw_transport_metadata(%{} = source_event) do
    transport = source_transport(source_event)
    keys = Map.get(@raw_metadata_keys, transport, [])

    metadata_sources =
      [
        source_event,
        Map.get(source_event, :metadata),
        Map.get(source_event, "metadata")
      ]
      |> Enum.filter(&is_map/1)

    metadata_sources
    |> unknown_raw_metadata(keys)
    |> Map.merge(known_raw_metadata(metadata_sources, keys))
  end

  def raw_transport_metadata(_source_event), do: %{}

  defp known_raw_metadata(metadata_sources, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch_metadata_value(metadata_sources, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp unknown_raw_metadata([_source_event | explicit_metadata_sources], known_keys) do
    known_key_strings = MapSet.new(known_keys, &Atom.to_string/1)
    known_keys = MapSet.new(known_keys)

    Enum.reduce(explicit_metadata_sources, %{}, fn metadata, acc ->
      metadata =
        Map.reject(metadata, fn
          {key, _value} when is_atom(key) -> MapSet.member?(known_keys, key)
          {key, _value} when is_binary(key) -> MapSet.member?(known_key_strings, key)
          {_key, _value} -> false
        end)

      Map.merge(acc, metadata)
    end)
  end

  defp unknown_raw_metadata(_metadata_sources, _known_keys), do: %{}

  defp fetch_metadata_value(metadata_sources, key) do
    string_key = Atom.to_string(key)

    Enum.find_value(metadata_sources, :error, fn metadata ->
      cond do
        Map.has_key?(metadata, key) -> {:ok, Map.fetch!(metadata, key)}
        Map.has_key?(metadata, string_key) -> {:ok, Map.fetch!(metadata, string_key)}
        true -> nil
      end
    end)
  end

  defp put_raw_event_metadata(%LifecycleEvent{raw_event: raw_event} = event, metadata)
       when is_map(raw_event) do
    %{event | raw_event: Map.merge(metadata, raw_event)}
  end

  defp put_raw_event_metadata(%{} = event, metadata) do
    case Map.get(event, :raw_event) || Map.get(event, "raw_event") do
      raw_event when is_map(raw_event) ->
        put_in_raw_event(event, Map.merge(metadata, raw_event))

      _raw_event ->
        event
    end
  end

  defp put_raw_event_metadata(event, _metadata), do: event

  defp put_in_raw_event(event, raw_event) when is_map_key(event, :raw_event) do
    Map.put(event, :raw_event, raw_event)
  end

  defp put_in_raw_event(event, raw_event), do: Map.put(event, "raw_event", raw_event)
end
