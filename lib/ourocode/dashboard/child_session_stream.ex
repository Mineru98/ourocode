defmodule Ourocode.Dashboard.ChildSessionStream do
  @moduledoc """
  Normalizes child-session stream cursors and renderable stream entries.
  """

  alias Ourocode.Journal
  alias Ourocode.MCP.ChildSessionCreationParser

  @spec stream_cursor(map(), atom(), integer(), String.t()) :: map()
  def stream_cursor(event, transport, event_seq, child_id) do
    event
    |> upstream_stream_cursor()
    |> Map.merge(%{
      transport: transport,
      event_seq: event_seq,
      child_id: child_id
    })
  end

  @spec stream_entries_for_event(map(), integer(), integer()) :: [map()]
  def stream_entries_for_event(event, event_seq, occurred_at_ms) do
    payload = stream_payload(event)

    if payload == %{} do
      []
    else
      [stream_entry(event, event_seq, occurred_at_ms, payload)]
    end
  end

  defp upstream_stream_cursor(event) do
    event
    |> stream_cursor_candidates()
    |> Enum.find_value(%{}, &cursor_from_payload/1)
  end

  defp stream_cursor_candidates(event) do
    [
      event,
      Map.get(event, :params),
      Map.get(event, "params"),
      Map.get(event, :notification),
      Map.get(event, "notification"),
      get_path(event, [:notification, "params"]),
      get_path(event, [:notification, :params]),
      get_path(event, ["notification", "params"]),
      get_path(event, ["notification", :params]),
      Map.get(event, :result),
      Map.get(event, "result"),
      get_path(event, [:result, "params"]),
      get_path(event, [:result, :params]),
      get_path(event, ["result", "params"]),
      get_path(event, ["result", :params]),
      Map.get(event, :raw_event),
      Map.get(event, "raw_event"),
      get_path(event, [:raw_event, "data"]),
      get_path(event, [:raw_event, :data]),
      get_path(event, ["raw_event", "data"]),
      get_path(event, ["raw_event", :data]),
      get_path(event, [:raw_event, "data", "params"]),
      get_path(event, [:raw_event, :data, :params]),
      get_path(event, ["raw_event", "data", "params"]),
      get_path(event, ["raw_event", :data, :params]),
      get_path(event, [:raw_event, "data", "result"]),
      get_path(event, [:raw_event, :data, :result]),
      get_path(event, ["raw_event", "data", "result"]),
      get_path(event, ["raw_event", :data, :result])
    ]
    |> Enum.filter(&is_map/1)
  end

  defp cursor_from_payload(payload) when is_map(payload) do
    payload
    |> get_in_any([
      "stream_cursor",
      :stream_cursor,
      "streamCursor",
      :streamCursor,
      "cursor",
      :cursor
    ])
    |> normalize_stream_cursor()
  end

  defp cursor_from_payload(_payload), do: nil

  defp normalize_stream_cursor(cursor) when is_map(cursor), do: cursor
  defp normalize_stream_cursor(cursor) when is_binary(cursor), do: %{cursor: cursor}
  defp normalize_stream_cursor(cursor) when is_integer(cursor), do: %{cursor: cursor}
  defp normalize_stream_cursor(_cursor), do: nil

  defp stream_entry(event, event_seq, occurred_at_ms, payload) do
    stream_entry = %{
      event_seq: event_seq,
      runtime_seq: runtime_seq(payload),
      type: Map.get(event, :type),
      token: string_payload_value(payload, "token"),
      delta: string_payload_value(payload, "delta"),
      content: string_payload_value(payload, "content"),
      media_placeholders: media_placeholders(payload),
      payload: payload,
      occurred_at_ms: occurred_at_ms
    }

    Map.put(stream_entry, :child_event_id, child_event_id(event, stream_entry))
  end

  defp child_event_id(event, stream_entry) do
    case Map.get(event, :child_event_id) || Map.get(event, "child_event_id") do
      child_event_id when is_binary(child_event_id) and child_event_id != "" ->
        child_event_id

      _child_event_id ->
        event
        |> Map.put_new(:runtime_seq, Map.get(stream_entry, :runtime_seq))
        |> Map.put_new(:payload, Map.get(stream_entry, :payload))
        |> Journal.child_event_identity()
        |> case do
          {:ok, child_event_id} -> child_event_id
          {:error, _reason} -> nil
        end
    end
  end

  defp stream_payload(event) do
    candidates = stream_payload_candidates(event)

    Enum.find(candidates, &stream_payload?/1) ||
      cursorless_opencode_stream_payload(event, candidates) ||
      %{}
  end

  defp cursorless_opencode_stream_payload(event, candidates) do
    if cursorless_opencode_stream_event?(event) do
      Enum.find(candidates, &direct_child_stream_payload?/1) ||
        Enum.find(candidates, &child_stream_payload?/1)
    end
  end

  defp cursorless_opencode_stream_event?(event) do
    Map.get(event, :type) == :parent_call_event and
      Map.get(event, :runtime_source) == "opencode"
  end

  defp child_stream_payload?(payload) when is_map(payload) do
    ChildSessionCreationParser.extract_child_id(payload) != :ignore
  end

  defp child_stream_payload?(_payload), do: false

  defp direct_child_stream_payload?(payload) when is_map(payload) do
    present?(Map.get(payload, "childID")) or
      present?(Map.get(payload, :childID)) or
      present?(Map.get(payload, "child_id")) or
      present?(Map.get(payload, :child_id))
  end

  defp direct_child_stream_payload?(_payload), do: false

  defp stream_payload_candidates(event) do
    [
      Map.get(event, :params),
      Map.get(event, "params"),
      Map.get(event, :notification),
      Map.get(event, "notification"),
      get_path(event, [:notification, "params"]),
      get_path(event, [:notification, :params]),
      get_path(event, ["notification", "params"]),
      get_path(event, ["notification", :params]),
      Map.get(event, :result),
      Map.get(event, "result"),
      get_path(event, [:result, "params"]),
      get_path(event, [:result, :params]),
      get_path(event, ["result", "params"]),
      get_path(event, ["result", :params]),
      Map.get(event, :raw_event),
      Map.get(event, "raw_event"),
      get_path(event, [:raw_event, "data"]),
      get_path(event, [:raw_event, :data]),
      get_path(event, ["raw_event", "data"]),
      get_path(event, ["raw_event", :data]),
      get_path(event, [:raw_event, "data", "params"]),
      get_path(event, [:raw_event, :data, :params]),
      get_path(event, ["raw_event", "data", "params"]),
      get_path(event, ["raw_event", :data, :params]),
      get_path(event, [:raw_event, "data", "result"]),
      get_path(event, [:raw_event, :data, :result]),
      get_path(event, ["raw_event", "data", "result"]),
      get_path(event, ["raw_event", :data, :result])
    ]
    |> Enum.filter(&is_map/1)
  end

  defp stream_payload?(payload) when is_map(payload) do
    [
      "seq",
      :seq,
      "event_seq",
      :event_seq,
      "token",
      :token,
      "delta",
      :delta,
      "content",
      :content
    ]
    |> Enum.any?(fn key -> present?(Map.get(payload, key)) end)
  end

  defp stream_payload?(_payload), do: false

  defp runtime_seq(payload) do
    payload
    |> get_in_any(["seq", :seq, "event_seq", :event_seq])
    |> integer_or_nil()
  end

  defp string_payload_value(payload, key) do
    payload
    |> get_in_any([key, payload_key_atom(key)])
    |> string_or_nil()
  end

  defp payload_key_atom("token"), do: :token
  defp payload_key_atom("delta"), do: :delta
  defp payload_key_atom("content"), do: :content
  defp payload_key_atom(_key), do: nil

  defp media_placeholders(payload) when is_map(payload) do
    payload
    |> media_items()
    |> Enum.with_index(1)
    |> Enum.map(fn {_item, index} -> "[Image ##{index}]" end)
  end

  defp media_placeholders(_payload), do: []

  defp media_items(payload) when is_map(payload) do
    [
      get_in_any(payload, ["images", :images]),
      get_in_any(payload, ["image", :image]),
      get_in_any(payload, ["attachments", :attachments]),
      get_in_any(payload, ["media", :media])
    ]
    |> List.flatten()
    |> Enum.filter(&image_like?/1)
  end

  defp image_like?(%{} = item) do
    type = get_in_any(item, ["type", :type, "mime_type", :mime_type, "mimeType", :mimeType])

    src =
      get_in_any(item, [
        "url",
        :url,
        "data",
        :data,
        "source",
        :source,
        "path",
        :path,
        "base64",
        :base64
      ])

    image_type?(type) or present?(src)
  end

  defp image_like?(value) when is_binary(value), do: present?(value)
  defp image_like?(_value), do: false

  defp image_type?(type) when is_binary(type), do: String.starts_with?(type, "image")
  defp image_type?(_type), do: false

  defp get_in_any(payload, keys) when is_map(payload) do
    Enum.find_value(keys, fn key -> Map.get(payload, key) end)
  end

  defp get_in_any(_payload, _keys), do: nil

  defp get_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      case acc do
        map when is_map(map) -> {:cont, Map.get(map, key)}
        _other -> {:halt, nil}
      end
    end)
  end

  defp get_path(_payload, _path), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp string_or_nil(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true
end
