defmodule Ourocode.Runtime.WonderAnswer do
  @moduledoc """
  Converts active wonderTool checkpoints into captured decisions and runtime events.
  """

  alias Ourocode.WonderTool.DecisionFlow
  alias Ourocode.Runtime.WonderFreeTextAnswer

  @type combined :: %{
          required(:result) => map(),
          required(:handback) => String.t(),
          required(:token) => String.t()
        }

  @spec capture(map(), term()) :: {:ok, combined()} | {:error, term()}
  def capture(request, selections) when is_map(request) and is_list(selections) do
    questions = Map.get(request, :questions, [])

    if single_multi_select_question?(questions) do
      capture(request, %{"selectedOptions" => selections})
    else
      selections
      |> Enum.zip(questions)
      |> Enum.reduce_while({:ok, []}, fn {selection, question}, {:ok, acc} ->
        case DecisionFlow.capture(request, selection, question_id: Map.get(question, :id)) do
          {:ok, decision} -> {:cont, {:ok, [decision | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, []} -> {:error, :selection_required}
        {:ok, decisions} -> {:ok, combine_decisions(Enum.reverse(decisions))}
        error -> error
      end
    end
  end

  def capture(request, selection) when is_map(request) do
    case DecisionFlow.capture(request, selection) do
      {:ok, decision} -> {:ok, combine_decisions([decision])}
      {:error, _reason} -> capture_free_text(request, selection)
    end
  end

  def capture(_request, _selection), do: {:error, :request_must_be_map}

  @spec cancelled(map(), String.t()) :: map()
  def cancelled(detection, reason) when is_map(detection) and is_binary(reason) do
    %{
      cancelled: true,
      reason: cancel_reason(reason),
      question_id: question_id(detection)
    }
  end

  @spec ack_event(map(), combined()) :: map()
  def ack_event(detection, %{result: decision, token: token}) do
    %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: Map.get(detection, :parent_call_id),
      child_id: Map.get(detection, :child_id),
      runtime_source: "ouroboros",
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        kind: :wonder_tool_answer,
        question_id: decision.question_id,
        token: "answered: " <> token
      }
    }
  end

  @spec cancel_event(map(), map()) :: map()
  def cancel_event(detection, cancelled) when is_map(detection) and is_map(cancelled) do
    %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: Map.get(detection, :parent_call_id),
      child_id: Map.get(detection, :child_id),
      runtime_source: "ouroboros",
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        kind: :wonder_tool_cancelled,
        question_id: cancelled.question_id,
        token: "declined: " <> cancelled.reason
      }
    }
  end

  defp capture_free_text(request, selection) do
    with {:ok, decision} <- WonderFreeTextAnswer.capture(request, selection) do
      {:ok, combine_decisions([decision])}
    end
  end

  defp single_multi_select_question?([question]) do
    Map.get(question, :multi_select?, false) == true
  end

  defp single_multi_select_question?(_questions), do: false

  defp combine_decisions([decision]) do
    %{result: decision, handback: decision.selected_label, token: decision.selected_label}
  end

  defp combine_decisions(decisions) do
    label = Enum.map_join(decisions, "; ", & &1.selected_label)

    handback =
      Enum.map_join(decisions, "\n", fn decision ->
        "#{decision.question_id}: #{decision.selected_label}"
      end)

    {first, _rest} = List.pop_at(decisions, 0)

    result =
      first
      |> Map.put(:decisions, decisions)
      |> Map.put(:selected_label, label)

    %{result: result, handback: handback, token: label}
  end

  defp cancel_reason(reason) do
    reason
    |> String.trim()
    |> case do
      "" -> "cancel"
      text -> text
    end
  end

  defp question_id(%{request: %{questions: [%{} = question | _rest]}}) do
    Map.get(question, :id) || Map.get(question, "id")
  end

  defp question_id(_detection), do: nil
end
