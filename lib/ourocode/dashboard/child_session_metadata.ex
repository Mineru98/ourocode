defmodule Ourocode.Dashboard.ChildSessionMetadata do
  @moduledoc """
  Metadata parsing and runtime identity normalization for child-session panes.
  """

  @pane_lifecycle_types MapSet.new([
                          :child_pane_registered,
                          :child_pane_opened,
                          :child_pane_focused,
                          :child_pane_updated,
                          :child_pane_completed,
                          :child_pane_cancelled
                        ])

  @runtime_identity_keys [
    :native_session_id,
    :nativeSessionID,
    :nativeSessionId,
    "native_session_id",
    "nativeSessionID",
    "nativeSessionId",
    :execution_id,
    :executionID,
    :executionId,
    "execution_id",
    "executionID",
    "executionId",
    :lineage_id,
    :lineageID,
    :lineageId,
    "lineage_id",
    "lineageID",
    "lineageId",
    :job_id,
    :jobID,
    :jobId,
    "job_id",
    "jobID",
    "jobId",
    :call_id,
    :callID,
    :callId,
    :input_call_id,
    :inputCallID,
    :inputCallId,
    "call_id",
    "callID",
    "callId",
    "input_call_id",
    "inputCallID",
    "inputCallId",
    :childID,
    :childId,
    :child_id,
    "childID",
    "childId",
    "child_id",
    :session_id,
    :sessionID,
    :sessionId,
    :_sessionId,
    "session_id",
    "sessionID",
    "sessionId",
    "_sessionId",
    :thread_id,
    :threadID,
    :threadId,
    "thread_id",
    "threadID",
    "threadId"
  ]

  @spec string(map(), atom()) :: {:ok, String.t()} | :error
  def string(metadata, key) do
    value =
      metadata
      |> value(key)
      |> normalize_runtime_id()

    case value do
      nil -> :error
      value -> {:ok, value}
    end
  end

  @spec string_any(map(), [atom()]) :: {:ok, String.t()} | :error
  def string_any(metadata, keys) when is_list(keys) do
    Enum.find_value(keys, :error, fn key ->
      case string(metadata, key) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end)
  end

  @spec transport(map()) :: {:ok, :stdio | :streamable_http | :sse} | :error
  def transport(metadata) do
    case value(metadata, :transport) do
      transport when transport in [:stdio, :streamable_http, :sse] -> {:ok, transport}
      "stdio" -> {:ok, :stdio}
      "streamable_http" -> {:ok, :streamable_http}
      "sse" -> {:ok, :sse}
      _transport -> :error
    end
  end

  @spec integer(map(), atom()) :: integer() | nil
  def integer(metadata, key) do
    case value(metadata, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _value -> nil
    end
  end

  @spec map_value(map(), atom(), map()) :: map()
  def map_value(metadata, key, default) do
    case value(metadata, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  @spec acknowledged_stream_cursor(map()) :: map() | nil
  def acknowledged_stream_cursor(metadata) do
    case value(metadata, :last_acknowledged_stream_cursor) ||
           value(metadata, :acknowledged_stream_cursor) do
      cursor when is_map(cursor) -> cursor
      _cursor -> nil
    end
  end

  @spec pane_projection_state(map()) :: map()
  def pane_projection_state(metadata) do
    metadata
    |> map_value(:pane_state, %{})
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, pane_state_key(key), pane_state_value(key, value))
    end)
  end

  @spec lifecycle_type(map()) :: {:ok, atom()} | :error
  def lifecycle_type(event) do
    case value(event, :type) || value(event, :event_type) do
      type when is_atom(type) ->
        if MapSet.member?(@pane_lifecycle_types, type), do: {:ok, type}, else: :error

      type when is_binary(type) ->
        normalized = String.trim(type)

        Enum.find_value(@pane_lifecycle_types, :error, fn lifecycle_type ->
          if Atom.to_string(lifecycle_type) == normalized, do: {:ok, lifecycle_type}
        end)

      _type ->
        :error
    end
  end

  @spec status(map(), atom()) :: :working | :completed
  def status(event, lifecycle_type) do
    case value(event, :status) do
      status when status in [:working, :completed] -> status
      "working" -> :working
      "completed" -> :completed
      _status when lifecycle_type == :child_pane_completed -> :completed
      _status -> :working
    end
  end

  @spec pane_state(map(), map() | nil) :: map()
  def pane_state(metadata, nil) do
    %{
      open?: true,
      focused?: false,
      renderer: :default_child_session
    }
    |> Map.merge(map_value(metadata, :pane_state, %{}))
  end

  def pane_state(metadata, _existing_pane) do
    map_value(metadata, :pane_state, %{})
  end

  @spec normalize_stream_entry(term()) :: term()
  def normalize_stream_entry(entry) when is_map(entry) do
    Enum.reduce(entry, %{}, fn {key, value}, acc ->
      Map.put(acc, stream_entry_key(key), value)
    end)
  end

  def normalize_stream_entry(entry), do: entry

  @spec value(map(), atom()) :: term()
  def value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  @spec runtime_identity_keys() :: [atom() | String.t()]
  def runtime_identity_keys, do: @runtime_identity_keys

  @spec runtime_id_key?(atom() | String.t()) :: boolean()
  def runtime_id_key?(key), do: key in @runtime_identity_keys

  @spec present_runtime_id(map(), atom() | String.t()) :: String.t() | nil
  def present_runtime_id(external_ids, key) do
    external_ids
    |> Map.get(key)
    |> normalize_runtime_id()
  end

  @spec normalize_runtime_id(term()) :: String.t() | nil
  def normalize_runtime_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_runtime_id(_value), do: nil

  defp parse_integer(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _parse_error -> nil
    end
  end

  defp pane_state_key("open?"), do: :open?
  defp pane_state_key("focused?"), do: :focused?
  defp pane_state_key("renderer"), do: :renderer
  defp pane_state_key("last_event_seq"), do: :last_event_seq
  defp pane_state_key("last_acknowledged_stream_cursor"), do: :last_acknowledged_stream_cursor
  defp pane_state_key("acknowledged_stream_cursor"), do: :acknowledged_stream_cursor
  defp pane_state_key("stream_entries"), do: :stream_entries
  defp pane_state_key("title"), do: :title
  defp pane_state_key(key), do: key

  defp pane_state_value("stream_entries", entries) when is_list(entries) do
    Enum.map(entries, &normalize_stream_entry/1)
  end

  defp pane_state_value(:stream_entries, entries) when is_list(entries) do
    Enum.map(entries, &normalize_stream_entry/1)
  end

  defp pane_state_value("renderer", renderer), do: renderer_value(renderer)
  defp pane_state_value(:renderer, renderer), do: renderer_value(renderer)
  defp pane_state_value(_key, value), do: value

  defp renderer_value("default_child_session"), do: :default_child_session
  defp renderer_value("trusted_plugin_renderer"), do: :trusted_plugin_renderer
  defp renderer_value(renderer), do: renderer

  defp stream_entry_key("event_seq"), do: :event_seq
  defp stream_entry_key("runtime_seq"), do: :runtime_seq
  defp stream_entry_key("occurred_at_ms"), do: :occurred_at_ms
  defp stream_entry_key("token"), do: :token
  defp stream_entry_key("payload"), do: :payload
  defp stream_entry_key("child_event_id"), do: :child_event_id
  defp stream_entry_key(key), do: key
end
