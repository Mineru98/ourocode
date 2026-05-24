defmodule Ourocode.Journal.CleanupEventFields do
  @moduledoc """
  Normalized field accessors for cleanup journal events.
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

  @spec map_value(map(), atom(), map()) :: map()
  def map_value(event, key, default) do
    case value(event, key) do
      map when is_map(map) -> map
      _value -> default
    end
  end

  @spec string_value(map(), atom()) :: String.t() | nil
  def string_value(event, key) do
    case value(event, key) do
      nil -> nil
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  @spec integer_value(map(), atom()) :: integer() | nil
  def integer_value(event, key) do
    case value(event, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _other -> nil
        end

      _value ->
        nil
    end
  end

  @spec atom_value(map(), atom()) :: atom() | nil
  def atom_value(event, key) do
    case value(event, key) do
      value when is_atom(value) -> value
      value when is_binary(value) -> string_to_existing_cleanup_atom(value)
      _value -> nil
    end
  end

  @spec transport(map()) :: :stdio | :streamable_http | :sse | nil
  def transport(event) do
    case value(event, :transport) do
      transport when transport in [:stdio, :streamable_http, :sse] -> transport
      "stdio" -> :stdio
      "streamable_http" -> :streamable_http
      "sse" -> :sse
      _transport -> nil
    end
  end

  @spec session_id(map()) :: String.t() | nil
  def session_id(event) do
    string_value(event, :session_id) ||
      Map.get(map_value(event, :external_ids, %{}), "session_id")
  end

  defp normalize_nested(%{} = map) do
    Map.new(map, fn {key, value} -> {key, normalize_nested(value)} end)
  end

  defp normalize_nested(list) when is_list(list), do: Enum.map(list, &normalize_nested/1)
  defp normalize_nested(value), do: value

  defp normalize_key(key) when is_binary(key), do: top_level_key(key)
  defp normalize_key(key), do: key

  defp top_level_key("child_id"), do: :child_id
  defp top_level_key("cleanup_action"), do: :cleanup_action
  defp top_level_key("cleanup_reason"), do: :cleanup_reason
  defp top_level_key("cleanup_started_monotonic_ms"), do: :cleanup_started_monotonic_ms
  defp top_level_key("cleanup_state"), do: :cleanup_state
  defp top_level_key("created_at_ms"), do: :created_at_ms
  defp top_level_key("event_seq"), do: :event_seq
  defp top_level_key("event_type"), do: :event_type
  defp top_level_key("external_ids"), do: :external_ids
  defp top_level_key("error"), do: :error
  defp top_level_key("error_details"), do: :error_details
  defp top_level_key("idempotency_key"), do: :idempotency_key
  defp top_level_key("occurred_at_ms"), do: :occurred_at_ms
  defp top_level_key("pane_id"), do: :pane_id
  defp top_level_key("pane_state"), do: :pane_state
  defp top_level_key("parent_call_id"), do: :parent_call_id
  defp top_level_key("released_resources"), do: :released_resources
  defp top_level_key("replay_action"), do: :replay_action
  defp top_level_key("runtime_source"), do: :runtime_source
  defp top_level_key("session_id"), do: :session_id
  defp top_level_key("stale_cleanup_timeout_ms"), do: :stale_cleanup_timeout_ms
  defp top_level_key("stream_cursor"), do: :stream_cursor
  defp top_level_key("stream_kind"), do: :stream_kind

  defp top_level_key("stream_subscription_cleanup_timeout_ms") do
    :stream_subscription_cleanup_timeout_ms
  end

  defp top_level_key("transport"), do: :transport
  defp top_level_key("type"), do: :type
  defp top_level_key("updated_at_ms"), do: :updated_at_ms
  defp top_level_key(key), do: key

  defp string_to_existing_cleanup_atom("already_completed"), do: :already_completed
  defp string_to_existing_cleanup_atom("cancelled"), do: :cancelled
  defp string_to_existing_cleanup_atom("canceled"), do: :canceled
  defp string_to_existing_cleanup_atom("child"), do: :child
  defp string_to_existing_cleanup_atom("completed"), do: :completed
  defp string_to_existing_cleanup_atom("idle_timeout"), do: :idle_timeout
  defp string_to_existing_cleanup_atom("noop"), do: :noop
  defp string_to_existing_cleanup_atom("operation_timeout"), do: :operation_timeout

  defp string_to_existing_cleanup_atom("release_runtime_resources"),
    do: :release_runtime_resources

  defp string_to_existing_cleanup_atom("session"), do: :session
  defp string_to_existing_cleanup_atom("transport"), do: :transport
  defp string_to_existing_cleanup_atom(_value), do: nil
end
