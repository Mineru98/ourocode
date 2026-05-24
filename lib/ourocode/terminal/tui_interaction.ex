defmodule Ourocode.Terminal.TuiInteraction do
  @moduledoc false

  alias Ourocode.Terminal.{
    InterviewLiveState,
    InterviewPanel,
    TuiAnswerSubmission,
    TuiState,
    WonderNavigation
  }

  @spec handle_event(map(), map(), pid(), pid()) :: :ok
  def handle_event(%{key: :enter}, result, output, state) do
    answer = String.trim(TuiState.take_buffer(state))

    case TuiAnswerSubmission.submit_enter_answer(answer, result, output, state, context(result)) do
      :handled ->
        :ok

      :not_handled ->
        submit_wonder_selection(result, output, state)
    end
  end

  def handle_event(%{key: :escape}, result, output, _state) do
    case Map.get(result, :wonder_pause) do
      pause when is_function(pause, 0) ->
        pause.()
        log(output, "-- interview paused (type to talk to main session)")

      _none ->
        :ok
    end
  end

  def handle_event(_event, _result, _output, _state), do: :ok

  @spec submit_slash_answer(String.t(), map(), pid(), pid()) :: :ok
  def submit_slash_answer(answer, result, output, state) when is_binary(answer) do
    TuiAnswerSubmission.submit_free_text(answer, result, output, state, context(result))
  end

  @spec nav_event?(map(), String.t(), map(), pid()) :: boolean()
  def nav_event?(event, buffer, result, state) do
    WonderNavigation.nav_event?(
      event,
      buffer,
      wonder_detection(result),
      TuiState.wonder_nav(state)
    )
  end

  @spec handle_nav(map(), map(), pid()) :: :ok
  def handle_nav(event, result, state) do
    detection = wonder_detection(result)

    case nav_after(detection, TuiState.wonder_nav(state), event) do
      nil -> :ok
      nav -> TuiState.put_wonder_nav(state, nav)
    end

    :ok
  end

  @doc false
  def nav_after(detection, nav, event), do: WonderNavigation.after_event(detection, nav, event)

  @spec free_text_payload(map(), pid(), String.t()) :: map()
  def free_text_payload(result, state, answer) do
    WonderNavigation.free_text_payload(
      wonder_detection(result),
      TuiState.wonder_nav(state),
      answer
    )
  end

  defp context(result) do
    detection = wonder_detection(result)

    %{
      wonder_active?: detection != nil,
      wonder_detection: detection,
      interview_active?: interview_active?(result)
    }
  end

  @spec capturing?(map()) :: boolean()
  def capturing?(result) do
    (wonder_active?(result) or interview_active?(result)) and not paused?(result)
  end

  @spec wonder_active?(map()) :: boolean()
  def wonder_active?(result), do: wonder_detection(result) != nil

  @spec interview_active?(map()) :: boolean()
  def interview_active?(result), do: interview_state(result) != nil

  @spec paused?(map()) :: boolean()
  def paused?(result), do: InterviewLiveState.paused?(result)

  @spec wonder_detection(map()) :: map() | nil
  def wonder_detection(result), do: InterviewLiveState.wonder_tool(result)

  @spec interview_state(map()) :: map() | nil
  def interview_state(result), do: InterviewLiveState.interview(result)

  defp submit_wonder_selection(result, output, state) do
    cond do
      any_free_answer_selected?(result, state) ->
        :ok

      needs_review?(result, state) ->
        TuiState.put_wonder_nav(state, Map.put(TuiState.wonder_nav(state), :review?, true))
        TuiState.push_notification(state, "phase review - confirm answers before submit")

      true ->
        TuiState.push_notification(state, "phase submitting - sending selected answers")
        submit = Map.get(result, :wonder_answer)
        selections = selections(result, state)

        case submit && submit.(selections) do
          {:ok, decision} ->
            TuiState.push_notification(state, "phase accepted - answer captured")
            log(output, "you> #{Map.get(decision, :selected_label, "")}")

          _other ->
            :ok
        end
    end
  end

  defp needs_review?(result, state) do
    detection = wonder_detection(result)
    qcount = detection |> InterviewPanel.wonder_questions() |> length()
    nav = TuiState.wonder_nav(state)

    qcount > 1 and not Map.get(nav || %{}, :review?, false)
  end

  defp selections(result, state) do
    WonderNavigation.selections(wonder_detection(result), TuiState.wonder_nav(state))
  end

  defp any_free_answer_selected?(result, state) do
    WonderNavigation.any_free_answer_selected?(
      wonder_detection(result),
      TuiState.wonder_nav(state)
    )
  end

  defp log(output, text), do: IO.puts(output, text)
end
