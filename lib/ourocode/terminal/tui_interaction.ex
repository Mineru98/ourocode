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

  def handle_event(%{key: :escape}, result, output, state) do
    case Map.get(result, :wonder_pause) do
      pause when is_function(pause, 0) ->
        pause.()
        TuiState.put_force_interview_paused(state, true)
        TuiState.push_notification(state, "paused - /answer resumes, /cancel stops", 2_500)
        log(output, "-- interview paused (type normally to discuss; /answer <text> resumes)")

      _none ->
        :ok
    end
  end

  def handle_event(_event, _result, _output, _state), do: :ok

  @spec submit_slash_answer(String.t(), map(), pid(), pid()) :: :ok
  def submit_slash_answer(answer, result, output, state) when is_binary(answer) do
    TuiState.put_force_interview_paused(state, false)
    TuiAnswerSubmission.submit_free_text(answer, result, output, state, context(result))
  end

  @spec submit_cancel(map(), pid(), pid()) :: :handled | :not_handled
  def submit_cancel(result, output, state) do
    cond do
      wonder_active?(result) ->
        TuiState.push_notification(state, "step submitting - cancelling checkpoint")

        case Map.get(result, :wonder_cancel) do
          cancel when is_function(cancel, 1) ->
            case cancel.("cancel") do
              {:ok, _cancelled} ->
                TuiState.put_force_interview_paused(state, false)
                TuiState.put_wonder_nav(state, nil)
                stop_interview_after_cancel(result, state)
                show_cancelled_workspace(state)
                clear_captured_activity(output)
                :handled

              _other ->
                :not_handled
            end

          _none ->
            stop_plain_interview(result, output, state)
        end

      interview_active?(result) ->
        stop_plain_interview(result, output, state)

      true ->
        :not_handled
    end
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

  @spec capturing?(map(), pid()) :: boolean()
  def capturing?(result, state) when is_pid(state) do
    capturing?(result) and not TuiState.interview_cancelled?(state)
  end

  @spec wonder_active?(map()) :: boolean()
  def wonder_active?(result), do: wonder_detection(result) != nil

  @spec interview_active?(map()) :: boolean()
  def interview_active?(result) do
    case interview_state(result) do
      %{} = interview -> Map.get(interview, :complete) in [nil, false]
      _none -> false
    end
  end

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
        TuiState.push_notification(state, "step review - confirm answers before submit")

      true ->
        TuiState.push_notification(state, "step submitting - sending selected answers")
        submit = Map.get(result, :wonder_answer)
        selections = selections(result, state)

        case submit && submit.(selections) do
          {:ok, decision} ->
            selected = Map.get(decision, :selected_label, "")
            TuiState.push_notification(state, accepted_notification(selected))
            log(output, "you> #{selected}")

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

  defp accepted_notification(""), do: "accepted - answer captured"
  defp accepted_notification(label), do: "accepted - " <> label

  defp log(output, text), do: IO.puts(output, text)

  defp clear_captured_activity(output) do
    StringIO.flush(output)
    :ok
  rescue
    _exception -> :ok
  end

  defp stop_interview_after_cancel(result, state) do
    if interview_active?(result) do
      TuiState.push_notification(state, "cancelled - interview stopped")
    else
      TuiState.push_notification(state, "cancelled - checkpoint closed")
    end
  end

  defp stop_plain_interview(result, output, state) do
    case send_interview_cancel(result) do
      :ok ->
        TuiState.put_force_interview_paused(state, false)
        TuiState.push_notification(state, "cancelled - interview stopped")
        show_cancelled_workspace(state)
        clear_captured_activity(output)
        :handled

      :error ->
        :not_handled
    end
  end

  defp show_cancelled_workspace(state) do
    TuiState.put_scroll(state, 0)
    TuiState.put_interview_cancelled(state, true)

    TuiState.put_workspace(state, %{
      kind: "interview",
      title: "Interview Stopped",
      status: "cancelled",
      selected: "cancelled:interview",
      records: [
        %{
          id: "cancelled:interview",
          title: "Interview",
          state: "stopped",
          health: "clean"
        }
      ],
      detail: %{
        id: "cancelled:interview",
        title: "Interview stopped",
        state: "stopped",
        fields: %{
          step: "cancel acknowledged",
          current: "no active question is waiting",
          progress: "checkpoint closed and composer restored",
          controls: "type a new goal, /agents, or /verify",
          evidence: "stale interview activity cleared"
        },
        actions: [
          action("start", "Start PM", "ooo pm <goal>", "Enter"),
          action("agents", "View agents", "/agents", "a")
        ]
      },
      actions: [
        action("start", "Start PM", "ooo pm <goal>", "Enter"),
        action("agents", "View agents", "/agents", "a"),
        action("verify", "Run verifier", "/verify", "v")
      ],
      shortcuts: ["Up/Dn rows", "Enter action", "type to compose"],
      next:
        "Start another guided run with ooo pm <goal>, ooo interview <goal>, or ooo auto <goal>."
    })
  end

  defp action(id, label, command, shortcut) do
    %{id: id, label: label, command: command, shortcut: shortcut, enabled: true}
  end

  defp send_interview_cancel(result) do
    case Map.get(result, :interview_cancel) do
      cancel when is_function(cancel, 0) ->
        case cancel.() do
          {:ok, _text} -> :ok
          _other -> :error
        end

      _none ->
        send_interview_cancel_answer(result)
    end
  end

  defp send_interview_cancel_answer(result) do
    case Map.get(result, :interview_answer) do
      send_answer when is_function(send_answer, 1) ->
        case send_answer.("cancel") do
          {:ok, _text} -> :ok
          _other -> :error
        end

      _none ->
        :error
    end
  end
end
