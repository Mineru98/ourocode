defmodule Ourocode.MCP.RuntimeEventParser do
  @moduledoc """
  Extracts trusted external runtime IDs from supported Codex/CLI event payloads.

  The parser is intentionally transport-neutral: stdio JSONL, SSE, and
  streamable HTTP normalizers can pass decoded payload maps here and receive the
  same normalized `external_ids` shape for the journal and panes.
  """

  alias Ourocode.MCP.RuntimeEventPath

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
    Enum.find_value(RuntimeEventPath.supported_containers(), fn path ->
      with {:ok, container} <- RuntimeEventPath.fetch(event, path) do
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
    Enum.find_value(RuntimeEventPath.input_containers(), fn path ->
      with {:ok, container} <- RuntimeEventPath.fetch(event, path) do
        first_id_value(container, keys)
      else
        :error -> nil
      end
    end)
  end

  defp first_supported_input_identity(event) do
    Enum.find_value(RuntimeEventPath.input_containers(), fn path ->
      with {:ok, container} <- RuntimeEventPath.fetch(event, path),
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
