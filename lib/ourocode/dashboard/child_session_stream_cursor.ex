defmodule Ourocode.Dashboard.ChildSessionStreamCursor do
  @moduledoc """
  Extracts and normalizes child-session stream cursors from lifecycle events.
  """

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
end
