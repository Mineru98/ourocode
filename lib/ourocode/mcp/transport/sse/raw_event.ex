defmodule Ourocode.MCP.Transport.SSE.RawEvent do
  @moduledoc """
  Raw SSE frame metadata, sidecar storage, and canonical journal records.
  """

  alias Ourocode.MCP.LifecycleEvent

  @spec build_record(map(), map()) :: map()
  def build_record(%{} = raw_event, context) when is_map(context) do
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

  @spec context(map(), binary()) :: map()
  def context(%{} = transport_state, raw_payload) when is_binary(raw_payload) do
    timestamp_ms = System.system_time(:millisecond)
    sse_fields = frame_metadata(raw_payload)
    raw_payload_ref = raw_payload_ref(raw_payload)

    raw_payload_stored? =
      store_raw_payload(
        Map.get(transport_state, :raw_payload_store_dir),
        raw_payload,
        raw_payload_ref
      )

    Map.merge(
      %{
        endpoint_url: Map.fetch!(transport_state, :endpoint_url),
        connection_identifier: Map.fetch!(transport_state, :connection_identifier),
        session_identifier: Map.fetch!(transport_state, :session_identifier),
        timestamp_ms: timestamp_ms,
        raw_payload_ref: raw_payload_ref,
        raw_payload_stored?: raw_payload_stored?,
        raw_payload_size_bytes: byte_size(raw_payload)
      },
      sse_fields
    )
  end

  @spec frame_metadata(binary()) :: map()
  def frame_metadata(frame) when is_binary(frame) do
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

  def frame_metadata(_raw_payload) do
    %{
      sse_event_id: nil,
      sse_event_id_present: false,
      sse_event_type: nil,
      sse_event_type_present: false
    }
  end

  @spec raw_payload_path(Path.t(), String.t()) :: Path.t()
  def raw_payload_path(store_dir, "sha256:" <> digest) when is_binary(store_dir) do
    Path.join(store_dir, "sha256-" <> digest <> ".raw")
  end

  @spec default_store_dir(Path.t() | nil) :: Path.t() | nil
  def default_store_dir(nil), do: nil
  def default_store_dir(journal_path), do: journal_path <> ".raw_sse_payloads"

  @spec canonical_journal_event(LifecycleEvent.t() | map()) :: map()
  def canonical_journal_event(%LifecycleEvent{} = event) do
    event
    |> Map.from_struct()
    |> compact_journal_event()
  end

  def canonical_journal_event(%{} = event), do: compact_journal_event(event)

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

  defp compact_journal_event(event) do
    event
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
