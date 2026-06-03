defmodule Ourocode.ACP.Event do
  @moduledoc """
  Normalizes runtime/MCP lifecycle events into Agent Control Plane events.

  ACP is the agent-facing contract above transports. MCP, Grok-style stdio
  agents, and Ouroboros workflow streams can keep their native envelopes, while
  the TUI and future headless clients consume a small stable event family.
  """

  alias Ourocode.MCP.ChildSessionCreationParser
  alias Ourocode.WonderTool.Bridge, as: WonderBridge
  alias Ourocode.WonderTool.InteractionDetector

  @parent_call_types [
    :parent_call_started,
    :parent_call_event,
    :parent_call_result,
    :parent_call_failed,
    :parent_call_write_failed,
    :parent_call_unmatched_result
  ]

  @workflow_types [
    :workflow_run_started,
    :workflow_run_waiting,
    :workflow_evidence_recorded,
    :workflow_retry_scheduled,
    :workflow_needs_user,
    :workflow_run_completed,
    :workflow_run_failed,
    :workflow_run_cancelled
  ]

  @decision_result_types [:decision_answered, :decision_cancelled, :permission_result]

  @type t :: %{
          required(:kind) => :acp_event,
          required(:schema_version) => pos_integer(),
          required(:type) => atom(),
          required(:source_protocol) => atom(),
          optional(:parent_call_id) => String.t(),
          optional(:child_id) => String.t(),
          optional(:decision_id) => String.t()
        }

  @doc """
  Returns all ACP events represented by a normalized runtime event.

  A single MCP lifecycle frame can simultaneously advance a parent tool call,
  reveal a child session, and request a user decision, so this returns a list.
  """
  @spec from_runtime_event(map() | struct() | term()) :: [t()]
  def from_runtime_event(%_{} = event), do: event |> Map.from_struct() |> from_runtime_event()

  def from_runtime_event(event) when is_map(event) do
    [
      workflow_run_event(event),
      tool_call_event(event),
      agent_session_event(event),
      decision_result_event(event),
      decision_request_event(event)
    ]
    |> Enum.reject(&is_nil/1)
  end

  def from_runtime_event(_event), do: []

  defp workflow_run_event(event) do
    with true <- Map.get(event, :type) in @workflow_types,
         {:ok, workflow_run_id} <- required_string(event, :workflow_run_id) do
      event
      |> base_event(:workflow_run)
      |> Map.merge(%{
        workflow_run_id: workflow_run_id,
        parent_call_id: string_value(event, :parent_call_id),
        lifecycle: Map.get(event, :type),
        status: Map.get(event, :status),
        route: Map.get(event, :route),
        adapter_route: Map.get(event, :adapter_route),
        attempt: Map.get(event, :attempt),
        max_attempts: Map.get(event, :max_attempts),
        reason: Map.get(event, :reason)
      })
      |> drop_nil_values()
    else
      _other -> nil
    end
  end

  defp tool_call_event(event) do
    with true <- Map.get(event, :type) in @parent_call_types,
         {:ok, parent_call_id} <- required_string(event, :parent_call_id) do
      event
      |> base_event(:tool_call)
      |> Map.merge(%{
        parent_call_id: parent_call_id,
        tool_call_id: parent_call_id,
        lifecycle: Map.get(event, :type),
        status: tool_call_status(Map.get(event, :type))
      })
      |> maybe_put(:request_id, string_value(event, :request_id))
      |> maybe_put(:method, string_value(event, :method))
      |> maybe_put(:tool_name, tool_name(event))
      |> maybe_put(:params, Map.get(event, :params))
    else
      _other -> nil
    end
  end

  defp agent_session_event(event) do
    with true <-
           Map.get(event, :type) in [
             :parent_call_started,
             :parent_call_event,
             :parent_call_result
           ],
         {:ok, parent_call_id} <- required_string(event, :parent_call_id),
         {:ok, extraction} <- child_extraction(event) do
      event
      |> base_event(:agent_session)
      |> Map.merge(%{
        parent_call_id: parent_call_id,
        child_id: extraction.child_id,
        session_id: extraction.child_id,
        pane_key: extraction.pane_key,
        id_source: extraction.source,
        payload_path: extraction.payload_path,
        lifecycle: Map.get(event, :type),
        status: agent_session_status(event)
      })
    else
      _other -> nil
    end
  end

  defp decision_request_event(event) do
    event
    |> decision_payloads()
    |> Enum.find_value(fn payload ->
      case InteractionDetector.detect(payload) do
        {:ok, detection} -> detection
        :ignore -> nil
      end
    end)
    |> case do
      nil ->
        nil

      detection ->
        event
        |> base_event(:decision_request)
        |> Map.merge(%{
          decision_id: Map.get(detection, :request_id) || fallback_decision_id(event),
          parent_call_id:
            Map.get(detection, :parent_call_id) || string_value(event, :parent_call_id),
          child_id: Map.get(detection, :child_id),
          status: :pending,
          question_count: Map.get(detection, :question_count),
          option_counts: Map.get(detection, :option_counts),
          checkpoint_kinds: Map.get(detection, :checkpoint_kinds, [])
        })
        |> drop_nil_values()
    end
  end

  defp decision_result_event(event) do
    with true <- Map.get(event, :type) in @decision_result_types,
         {:ok, decision_id} <- required_string(event, :decision_id) do
      event
      |> base_event(:decision_result)
      |> Map.merge(%{
        decision_id: decision_id,
        parent_call_id: string_value(event, :parent_call_id),
        child_id: string_value(event, :child_id),
        status: decision_result_status(Map.get(event, :type)),
        selected_label: string_value(event, :selected_label),
        reason: string_value(event, :reason)
      })
      |> drop_nil_values()
    else
      _other -> nil
    end
  end

  defp base_event(event, type) do
    %{
      kind: :acp_event,
      schema_version: 1,
      type: type,
      source_protocol: :mcp,
      source_event_type: Map.get(event, :type),
      runtime_source: string_value(event, :runtime_source),
      transport: Map.get(event, :transport),
      event_seq: Map.get(event, :event_seq),
      occurred_at_ms: Map.get(event, :occurred_at_ms)
    }
    |> drop_nil_values()
  end

  defp payloads(event) do
    [
      event,
      Map.get(event, :notification),
      Map.get(event, :result),
      Map.get(event, :params),
      get_in(event, [:notification, "params"]),
      get_in(event, [:notification, :params]),
      get_in(event, [:result, "params"]),
      get_in(event, [:result, :params])
    ]
    |> Enum.filter(&is_map/1)
  end

  defp decision_payloads(event) do
    bridged =
      case WonderBridge.to_detection_payload(event) do
        {:ok, payload} -> [payload]
        :ignore -> []
      end

    bridged ++ payloads(event)
  end

  defp child_extraction(event) do
    case ChildSessionCreationParser.extract(event) do
      {:ok, extraction} -> {:ok, extraction}
      _other -> :error
    end
  end

  defp tool_call_status(:parent_call_started), do: :starting
  defp tool_call_status(:parent_call_event), do: :streaming
  defp tool_call_status(:parent_call_result), do: :completed
  defp tool_call_status(:parent_call_unmatched_result), do: :completed
  defp tool_call_status(_failed), do: :failed

  defp agent_session_status(%{type: :parent_call_result} = event) do
    if completed_result?(event), do: :completed, else: :streaming
  end

  defp agent_session_status(_event), do: :streaming

  defp decision_result_status(:decision_answered), do: :answered
  defp decision_result_status(:decision_cancelled), do: :cancelled
  defp decision_result_status(:permission_result), do: :resolved

  defp completed_result?(event) do
    event
    |> completion_candidates()
    |> Enum.any?(&completed_status?/1)
  end

  defp completion_candidates(event) do
    [
      Map.get(event, :status),
      Map.get(event, "status"),
      get_in(event, [:result, "status"]),
      get_in(event, [:result, :status]),
      get_in(event, [:raw_event, "result", "status"]),
      get_in(event, [:raw_event, :result, :status]),
      get_in(event, [:raw_event, "data", "result", "status"]),
      get_in(event, [:raw_event, :data, :result, :status])
    ]
  end

  defp completed_status?(status) when status in [:completed, :complete, :done], do: true

  defp completed_status?(status) when is_binary(status) do
    status
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["completed", "complete", "done", "succeeded", "success"]))
  end

  defp completed_status?(_status), do: false

  defp tool_name(event) do
    string_value(event, :method) ||
      get_in(event, [:params, "name"]) ||
      get_in(event, [:params, :name]) ||
      get_in(event, [:notification, "params", "name"]) ||
      get_in(event, [:notification, :params, :name])
  end

  defp fallback_decision_id(event) do
    case string_value(event, :parent_call_id) do
      nil -> nil
      parent_call_id -> parent_call_id <> ":decision"
    end
  end

  defp required_string(event, key) do
    case Map.get(event, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> :error
    end
  end

  defp string_value(event, key) do
    case Map.get(event, key) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
