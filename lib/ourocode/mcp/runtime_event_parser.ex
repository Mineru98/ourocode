defmodule Ourocode.MCP.RuntimeEventParser do
  @moduledoc """
  Extracts trusted external runtime IDs from supported Codex/CLI event payloads.

  The parser is intentionally transport-neutral: stdio JSONL, SSE, and
  streamable HTTP normalizers can pass decoded payload maps here and receive the
  same normalized `external_ids` shape for the journal and panes.
  """

  @type external_ids :: %{
          optional(:childID) => String.t(),
          optional(:child_id) => String.t(),
          optional(:job_id) => String.t(),
          optional(:execution_id) => String.t(),
          optional(:lineage_id) => String.t(),
          optional(:native_session_id) => String.t(),
          optional(:session_id) => String.t(),
          optional(:thread_id) => String.t(),
          optional(:input_session_id) => String.t(),
          optional(:input_call_id) => String.t(),
          optional(:input) => map()
        }

  @supported_containers [
    [],
    [:msg],
    [:message],
    [:event],
    [:payload],
    [:data],
    [:data, :params],
    [:data, :params, :metadata],
    [:data, :params, :meta],
    [:data, :result],
    [:data, :result, :metadata],
    [:data, :result, :meta],
    [:data, :input],
    [:params],
    [:params, :metadata],
    [:params, :meta],
    [:result],
    [:result, :metadata],
    [:result, :meta],
    [:input],
    [:msg, :payload],
    [:msg, :data],
    [:message, :payload],
    [:message, :data],
    [:event, :payload],
    [:event, :data],
    [:event, :data, :params],
    [:event, :data, :params, :metadata],
    [:event, :data, :params, :meta],
    [:event, :data, :result],
    [:event, :data, :result, :metadata],
    [:event, :data, :result, :meta],
    [:event, :data, :input],
    [:params, :input],
    [:result, :input],
    [:raw_event],
    [:raw_event, :msg],
    [:raw_event, :message],
    [:raw_event, :event],
    [:raw_event, :payload],
    [:raw_event, :data],
    [:raw_event, :data, :params],
    [:raw_event, :data, :params, :metadata],
    [:raw_event, :data, :params, :meta],
    [:raw_event, :data, :result],
    [:raw_event, :data, :result, :metadata],
    [:raw_event, :data, :result, :meta],
    [:raw_event, :data, :input],
    [:raw_event, :params],
    [:raw_event, :params, :metadata],
    [:raw_event, :params, :meta],
    [:raw_event, :result],
    [:raw_event, :result, :metadata],
    [:raw_event, :result, :meta],
    [:raw_event, :event, :payload],
    [:raw_event, :event, :data],
    [:raw_event, :event, :data, :params],
    [:raw_event, :event, :data, :params, :metadata],
    [:raw_event, :event, :data, :params, :meta],
    [:raw_event, :event, :data, :result],
    [:raw_event, :event, :data, :result, :metadata],
    [:raw_event, :event, :data, :result, :meta],
    [:raw_event, :event, :data, :input],
    [:raw_event, :params, :input],
    [:raw_event, :result, :input]
  ]

  @native_session_id_keys [
    :native_session_id,
    :nativeSessionID,
    :nativeSessionId,
    "native_session_id",
    "nativeSessionID",
    "nativeSessionId"
  ]

  @child_id_keys [
    :childID,
    :childId,
    :child_id,
    :childSessionID,
    :childSessionId,
    :child_session_id,
    :agentSessionID,
    :agentSessionId,
    :agent_session_id,
    :opencode_childID,
    "childID",
    "childId",
    "child_id",
    "childSessionID",
    "childSessionId",
    "child_session_id",
    "agentSessionID",
    "agentSessionId",
    "agent_session_id",
    "opencode_childID"
  ]

  @job_id_keys [
    :job_id,
    :jobID,
    :jobId,
    "job_id",
    "jobID",
    "jobId"
  ]

  @execution_id_keys [
    :execution_id,
    :executionID,
    :executionId,
    "execution_id",
    "executionID",
    "executionId"
  ]

  @lineage_id_keys [
    :lineage_id,
    :lineageID,
    :lineageId,
    "lineage_id",
    "lineageID",
    "lineageId"
  ]

  @session_id_keys [
    :session_id,
    :sessionID,
    :sessionId,
    :_sessionId,
    "session_id",
    "sessionID",
    "sessionId",
    "_sessionId"
  ]

  @thread_id_keys [
    :thread_id,
    :threadID,
    :threadId,
    "thread_id",
    "threadID",
    "threadId"
  ]

  @input_containers [
    [:input],
    [:data, :input],
    [:params, :input],
    [:result, :input],
    [:msg, :input],
    [:msg, :payload, :input],
    [:msg, :data, :input],
    [:message, :input],
    [:message, :payload, :input],
    [:message, :data, :input],
    [:event, :input],
    [:event, :payload, :input],
    [:event, :data, :input],
    [:raw_event, :input],
    [:raw_event, :data, :input],
    [:raw_event, :params, :input],
    [:raw_event, :result, :input],
    [:raw_event, :msg, :input],
    [:raw_event, :msg, :payload, :input],
    [:raw_event, :msg, :data, :input],
    [:raw_event, :message, :input],
    [:raw_event, :message, :payload, :input],
    [:raw_event, :message, :data, :input],
    [:raw_event, :event, :input],
    [:raw_event, :event, :payload, :input],
    [:raw_event, :event, :data, :input]
  ]

  @input_session_id_keys [
    :sessionID,
    :sessionId,
    :session_id,
    "sessionID",
    "sessionId",
    "session_id"
  ]

  @input_call_id_keys [
    :callID,
    :callId,
    :call_id,
    "callID",
    "callId",
    "call_id"
  ]

  @doc """
  Extracts normalized Codex/CLI runtime IDs from a decoded event payload.

  Only known envelope paths are searched. Unknown payload shapes, blank values,
  and non-string values return an empty map rather than guessed IDs.
  """
  @spec extract_external_ids(map() | struct()) :: external_ids()
  def extract_external_ids(%_{} = event), do: event |> Map.from_struct() |> extract_external_ids()

  def extract_external_ids(event) when is_map(event) do
    %{}
    |> maybe_put(:childID, first_supported_id(event, @child_id_keys))
    |> maybe_put(:job_id, first_supported_id(event, @job_id_keys))
    |> maybe_put(:execution_id, first_supported_id(event, @execution_id_keys))
    |> maybe_put(:lineage_id, first_supported_id(event, @lineage_id_keys))
    |> maybe_put(:native_session_id, first_supported_id(event, @native_session_id_keys))
    |> maybe_put(:session_id, first_supported_id(event, @session_id_keys))
    |> maybe_put(:thread_id, first_supported_id(event, @thread_id_keys))
    |> maybe_put(:input_session_id, first_supported_input_id(event, @input_session_id_keys))
    |> maybe_put(:input_call_id, first_supported_input_id(event, @input_call_id_keys))
    |> maybe_put(:input, first_supported_input_identity(event))
  end

  def extract_external_ids(_event), do: %{}

  defp first_supported_id(event, keys) do
    Enum.find_value(@supported_containers, fn path ->
      with {:ok, container} <- fetch_path(event, path) do
        first_id_value(container, keys)
      else
        :error -> nil
      end
    end)
  end

  defp first_id_value(container, keys) when is_map(container) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(container, key) do
        {:ok, value} -> normalize_id(value)
        :error -> nil
      end
    end)
  end

  defp first_id_value(_container, _keys), do: nil

  defp first_supported_input_id(event, keys) do
    Enum.find_value(@input_containers, fn path ->
      with {:ok, container} <- fetch_path(event, path) do
        first_id_value(container, keys)
      else
        :error -> nil
      end
    end)
  end

  defp first_supported_input_identity(event) do
    Enum.find_value(@input_containers, fn path ->
      with {:ok, container} <- fetch_path(event, path),
           input when map_size(input) > 0 <- input_identity(container) do
        input
      else
        _ -> nil
      end
    end)
  end

  defp input_identity(container) when is_map(container) do
    %{}
    |> maybe_put("sessionID", first_id_value(container, @input_session_id_keys))
    |> maybe_put("callID", first_id_value(container, @input_call_id_keys))
  end

  defp input_identity(_container), do: %{}

  defp fetch_path(event, []), do: {:ok, event}

  defp fetch_path(event, [key | rest]) when is_map(event) do
    string_key = Atom.to_string(key)

    case Map.fetch(event, key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> fetch_string_path(event, string_key, rest)
    end
  end

  defp fetch_path(_event, _path), do: :error

  defp fetch_string_path(event, string_key, rest) do
    case Map.fetch(event, string_key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> :error
    end
  end

  defp normalize_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_id(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
