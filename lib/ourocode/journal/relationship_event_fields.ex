defmodule Ourocode.Journal.RelationshipEventFields do
  @moduledoc """
  Normalized field accessors for relationship recovery journal events.
  """

  @spec normalize(map()) :: map()
  def normalize(%_{} = event), do: event |> Map.from_struct() |> normalize()

  def normalize(event) when is_map(event) do
    Map.new(event, fn {key, value} ->
      {normalize_key(key), normalize_nested(value)}
    end)
  end

  @spec value(map(), atom()) :: term()
  def value(event, key), do: Map.get(event, key) || Map.get(event, Atom.to_string(key))

  @spec string_value(map(), atom()) :: String.t() | nil
  def string_value(event, key) do
    case value(event, key) do
      value when is_binary(value) -> String.trim(value)
      value when is_integer(value) -> Integer.to_string(value)
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _value -> nil
    end
  end

  @spec integer_value(map(), atom()) :: integer() | nil
  def integer_value(event, key) do
    case value(event, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} -> integer
          _parse_error -> nil
        end

      _value ->
        nil
    end
  end

  @spec map_value(map(), atom(), map()) :: map()
  def map_value(event, key, default) do
    case value(event, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  @spec transport(map()) :: {:ok, :stdio | :streamable_http | :sse} | {:error, :invalid_transport}
  def transport(event) do
    case value(event, :transport) do
      transport when transport in [:stdio, :streamable_http, :sse] -> {:ok, transport}
      "stdio" -> {:ok, :stdio}
      "streamable_http" -> {:ok, :streamable_http}
      "sse" -> {:ok, :sse}
      _transport -> {:error, :invalid_transport}
    end
  end

  defp normalize_nested(%{} = map) do
    Map.new(map, fn {key, value} -> {key, normalize_nested(value)} end)
  end

  defp normalize_nested(list) when is_list(list), do: Enum.map(list, &normalize_nested/1)
  defp normalize_nested(value), do: value

  defp normalize_key(key) when is_binary(key), do: top_level_key(key)
  defp normalize_key(key), do: key

  defp top_level_key("child_id"), do: :child_id
  defp top_level_key("created_at_ms"), do: :created_at_ms
  defp top_level_key("event_seq"), do: :event_seq
  defp top_level_key("event_type"), do: :event_type
  defp top_level_key("external_ids"), do: :external_ids
  defp top_level_key("acknowledged_stream_cursor"), do: :acknowledged_stream_cursor
  defp top_level_key("last_acknowledged_stream_cursor"), do: :last_acknowledged_stream_cursor
  defp top_level_key("id"), do: :id
  defp top_level_key("occurred_at_ms"), do: :occurred_at_ms
  defp top_level_key("pane_id"), do: :pane_id
  defp top_level_key("pane_state"), do: :pane_state
  defp top_level_key("parent_call_id"), do: :parent_call_id
  defp top_level_key("runtime_source"), do: :runtime_source
  defp top_level_key("stream_cursor"), do: :stream_cursor
  defp top_level_key("transport"), do: :transport
  defp top_level_key("type"), do: :type
  defp top_level_key("updated_at_ms"), do: :updated_at_ms
  defp top_level_key(key), do: key
end
