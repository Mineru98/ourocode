defmodule Ourocode.Dashboard.UITree.Event do
  @moduledoc """
  Normalizes lifecycle events for the canonical dashboard UI tree.
  """

  @lifecycle_types MapSet.new([
                     :parent_call_started,
                     :parent_call_event,
                     :parent_call_result,
                     :parent_call_failed,
                     :parent_call_write_failed,
                     :parent_call_unmatched_result,
                     :transport_decode_failed,
                     :transport_exited,
                     :transport_connected,
                     :transport_failed,
                     :transport_closed,
                     :transport_started,
                     :child_pane_registered,
                     :child_pane_opened,
                     :child_pane_focused,
                     :child_pane_updated,
                     :child_pane_completed
                   ])

  @spec normalize(map()) :: map()
  def normalize(%_{} = event) do
    event
    |> Map.from_struct()
    |> normalize()
  end

  def normalize(event) when is_map(event) do
    %{}
    |> maybe_put(:event_seq, integer_value(event, :event_seq))
    |> maybe_put(:type, lifecycle_type(event))
    |> maybe_put(:pane_id, string_value(event, :pane_id) || string_value(event, :id))
    |> maybe_put(:child_id, string_value(event, :child_id))
    |> maybe_put(:transport, transport(event))
    |> maybe_put(:parent_call_id, string_value(event, :parent_call_id))
    |> maybe_put(:runtime_source, string_value(event, :runtime_source))
    |> maybe_put(:external_ids, map_value(event, :external_ids, %{}))
    |> maybe_put(:stream_cursor, map_value(event, :stream_cursor, nil))
    |> maybe_put(:pane_state, map_value(event, :pane_state, nil))
    |> maybe_put(:occurred_at_ms, integer_value(event, :occurred_at_ms))
    |> maybe_put(:created_at_ms, integer_value(event, :created_at_ms))
    |> maybe_put(:updated_at_ms, integer_value(event, :updated_at_ms))
    |> maybe_put(:call_id, string_value(event, :call_id))
    |> maybe_put(:request_id, string_value(event, :request_id))
    |> maybe_put(:method, string_value(event, :method))
    |> maybe_put(:params, value(event, :params))
    |> maybe_put(:payload, value(event, :payload))
    |> maybe_put(:result, value(event, :result))
    |> maybe_put(:error, value(event, :error))
    |> maybe_put(:error_details, value(event, :error_details))
    |> maybe_put(:notification, map_value(event, :notification, nil))
    |> maybe_put(:status, integer_value(event, :status))
    |> maybe_put(:headers, value(event, :headers))
    |> maybe_put(:raw_event, map_value(event, :raw_event, nil))
  end

  @spec child_stream_event?(map()) :: boolean()
  def child_stream_event?(event) do
    not is_nil(child_id_from_external_ids(event) || child_id_from_payload(event))
  end

  defp child_id_from_external_ids(event) do
    case Map.get(event, :external_ids) do
      ids when is_map(ids) ->
        Map.get(ids, :childID) ||
          Map.get(ids, "childID") ||
          Map.get(ids, :child_id) ||
          Map.get(ids, "child_id")

      _ ->
        nil
    end
  end

  defp child_id_from_payload(event) do
    event
    |> stream_payload()
    |> case do
      payload when is_map(payload) ->
        Map.get(payload, "childID") ||
          Map.get(payload, :childID) ||
          Map.get(payload, "child_id") ||
          Map.get(payload, :child_id)

      _ ->
        nil
    end
  end

  defp stream_payload(event) do
    Map.get(event, :payload) ||
      get_in(event, [:notification, "params"]) ||
      get_in(event, [:notification, :params]) ||
      get_in(event, [:raw_event, "data", "params"]) ||
      get_in(event, [:raw_event, :data, :params])
  end

  defp lifecycle_type(event) do
    case value(event, :type) do
      type when is_atom(type) ->
        if MapSet.member?(@lifecycle_types, type), do: type

      type when is_binary(type) ->
        Enum.find(@lifecycle_types, &(Atom.to_string(&1) == type))

      _type ->
        nil
    end
  end

  defp transport(event) do
    case value(event, :transport) do
      transport when transport in [:stdio, :streamable_http, :sse] -> transport
      "stdio" -> :stdio
      "streamable_http" -> :streamable_http
      "sse" -> :sse
      _transport -> nil
    end
  end

  defp value(event, key) do
    Map.get(event, key) || Map.get(event, Atom.to_string(key))
  end

  defp string_value(event, key) do
    case value(event, key) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _value -> nil
    end
  end

  defp integer_value(event, key) do
    case value(event, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} -> integer
          _ -> nil
        end

      _value ->
        nil
    end
  end

  defp map_value(event, key, default) do
    case value(event, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
