defmodule Ourocode.Runtime.LoopBindingInterviewSession do
  @moduledoc """
  Runs the live interview relay used by terminal loop bindings.
  """

  alias Ourocode.Runtime.{
    InterviewEvents,
    InterviewProgress,
    InterviewAnswerRefiner,
    InterviewOptionGenerator,
    InterviewResponse,
    InterviewState,
    InterviewWonderPrompt,
    InterviewWorkflowInvocation,
    LoopBindingInterviewAwaiter,
    LoopBindingInterviewRound,
    LoopBindingInterviewSessionConfig,
    LoopBindingInterviewText
  }

  alias Ourocode.Runtime.LoopBindingInterviewSessionIO, as: SessionIO

  @spec run(pid(), keyword(), keyword()) :: :ok
  def run(agent, opts, defaults) when is_pid(agent) and is_list(opts) and is_list(defaults) do
    session = LoopBindingInterviewSessionConfig.build(opts, defaults)

    push_initial_interview_prompt(agent, session.payload)
    interview_round(agent, session)
  rescue
    exception ->
      callbacks = Keyword.get(defaults, :callbacks, %{})

      enqueue_failure(
        agent,
        Keyword.get(opts, :parent_call_id, "parent-interview"),
        {:interview_loop_exception, Exception.message(exception)},
        callbacks
      )

      :ok
  end

  defp push_initial_interview_prompt(agent, payload) do
    case LoopBindingInterviewText.initial_context_from_payload(payload) do
      text when is_binary(text) and text != "" ->
        SessionIO.push_dialogue(agent, :user, text)

      _none ->
        :ok
    end
  end

  defp interview_round(agent, %{round: round, max_rounds: max, parent_call_id: pcid} = st)
       when round > max do
    SessionIO.enqueue_complete(agent, pcid, :max_rounds, st.callbacks, run_id: st.workflow_run_id)
    :ok
  end

  defp interview_round(agent, st) do
    regular_interview_round(agent, st)
  end

  defp regular_interview_round(agent, st) do
    InterviewProgress.mark_waiting(agent, st)

    result = st.pcf.(st.payload)

    unless cancelled?(agent, st.parent_call_id) do
      handle_round_action(agent, st, result)
    end
  end

  defp handle_round_action(agent, st, result) do
    if cancelled?(agent, st.parent_call_id) do
      :ok
    else
      handle_live_round_action(agent, st, result)
    end
  end

  defp handle_live_round_action(agent, st, result) do
    case LoopBindingInterviewRound.action(result, st.session_id) do
      {:server_error, message, session_id} ->
        enqueue_server_error(agent, st.parent_call_id, message, session_id, st.callbacks)
        :ok

      {:waiting, message, meta, session_id} ->
        SessionIO.merge_status(agent, st.parent_call_id, message, meta, session_id)
        maybe_poll_waiting_status(agent, %{st | session_id: session_id})

      {:summarize_initial_context, meta, session_id} ->
        answer =
          st.payload
          |> LoopBindingInterviewText.initial_context_from_payload()
          |> LoopBindingInterviewText.summarize_initial_context(max_context_chars(meta))

        SessionIO.push_router_trace(
          agent,
          "main session summarized oversized initial context for MCP"
        )

        followup(agent, %{st | session_id: session_id}, "[from-user] " <> answer, st.streak)

      {:complete, text, meta, session_id} ->
        SessionIO.merge_interview(
          agent,
          st.parent_call_id,
          text,
          meta,
          session_id
        )

        SessionIO.enqueue_complete(
          agent,
          st.parent_call_id,
          :seed_ready,
          st.callbacks,
          run_id: st.workflow_run_id
        )

        :ok

      {:question, question, text, meta, session_id} ->
        SessionIO.enqueue(
          agent,
          InterviewEvents.question(st.parent_call_id, text, meta),
          st.callbacks
        )

        SessionIO.merge_interview(
          agent,
          st.parent_call_id,
          text,
          meta,
          session_id
        )

        SessionIO.push_dialogue(
          agent,
          :mcp,
          InterviewState.mcp_turn_text(text)
        )

        route_question(agent, %{st | session_id: session_id}, question)

      :missing_session_id ->
        enqueue_failure(
          agent,
          st,
          :interview_session_id_missing
        )

        :ok

      {:transport_failed, reason} ->
        enqueue_failure(agent, st, {:transport_failed, reason})
        :ok
    end
  end

  defp enqueue_server_error(agent, parent_call_id, message, session_id, callbacks) do
    status = InterviewEvents.server_error_status(message)

    SessionIO.enqueue(
      agent,
      InterviewEvents.server_error(parent_call_id, message, session_id),
      callbacks
    )

    Agent.update(agent, fn state ->
      InterviewEvents.server_error_state(state, message, session_id)
    end)

    SessionIO.push_dialogue(
      agent,
      :mcp,
      status <> InterviewEvents.resume_hint(session_id)
    )

    enqueue_failure(
      agent,
      parent_call_id,
      {:mcp_question_generator_unavailable, message, session_id},
      callbacks
    )

    :ok
  end

  defp route_question(agent, st, question) do
    question = InterviewResponse.clean_markdown(question)

    cond do
      cancelled?(agent, st.parent_call_id) ->
        :ok

      Map.get(st, :user_routed?, false) ->
        ask_user(agent, st, question, [])

      true ->
        SessionIO.push_router_trace(agent, "router: asking user directly")
        ask_user(agent, st, question, [])
    end
  end

  defp cancelled?(agent, parent_call_id) when is_pid(agent) and is_binary(parent_call_id) do
    Agent.get(agent, fn state ->
      cancelled? =
        state
        |> Map.get(:cancelled_interviews, MapSet.new())
        |> MapSet.member?(parent_call_id)

      complete? = get_in(state, [:interview, :complete]) == :user_done
      current_parent = get_in(state, [:interview, :parent_call_id])

      cancelled? or (complete? and current_parent in [nil, parent_call_id])
    end)
  end

  defp cancelled?(_agent, _parent_call_id), do: false

  defp ask_user(agent, st, prompt, options) do
    if cancelled?(agent, st.parent_call_id) do
      :ok
    else
      ask_live_user(agent, st, prompt, options)
    end
  end

  defp ask_live_user(agent, st, prompt, options) do
    options = generated_question_options(agent, st, prompt, options)

    SessionIO.push_dialogue(
      agent,
      :main,
      "→ asking you: " <> InterviewResponse.clean_markdown(prompt)
    )

    event = InterviewWonderPrompt.event(st.parent_call_id, st.round, prompt, options)

    maybe_enqueue_wonder_event(agent, event, options, st.callbacks)

    case LoopBindingInterviewAwaiter.await(agent, st.parent_call_id, prompt, options) do
      {:done, text} ->
        SessionIO.push_dialogue(agent, :user, text)

        SessionIO.enqueue_complete(agent, st.parent_call_id, :user_done, st.callbacks,
          run_id: st.workflow_run_id
        )

        :ok

      {:answer, user_text} ->
        if cancelled?(agent, st.parent_call_id) do
          :ok
        else
          refined_text = refine_user_answer(agent, st, user_text)
          SessionIO.push_dialogue(agent, :user, refined_text)

          followup(
            agent,
            %{st | user_routed?: true},
            LoopBindingInterviewText.ensure_user_prefix(refined_text),
            0
          )
        end
    end
  end

  defp event_options(event) do
    event
    |> get_in([:payload, "questions"])
    |> case do
      [%{"options" => options} | _rest] when is_list(options) -> options
      _other -> []
    end
  end

  defp maybe_enqueue_wonder_event(agent, event, [_first, _second | _rest], callbacks) do
    SessionIO.enqueue(agent, event, callbacks)
  end

  defp maybe_enqueue_wonder_event(agent, _event, _options, _callbacks) do
    SessionIO.push_router_trace(
      agent,
      "ACP answer choices unavailable; waiting for free-text answer"
    )

    :ok
  end

  defp generated_question_options(_agent, _st, _prompt, [_first | _rest] = options), do: options

  defp generated_question_options(agent, st, prompt, _options) do
    # Honor the configured router decision timeout (no upper clamp): the old
    # `min(1_500)` silently overrode the 3_000ms default and made option
    # generation fall back to free-text far too often. Keep the 250ms floor.
    timeout_ms = st |> Map.get(:router_decision_timeout_ms, 1_500) |> max(250)

    case InterviewOptionGenerator.generate(prompt, st.model,
           timeout_ms: timeout_ms,
           on_reason: fn chunk -> SessionIO.push_reasoning(agent, chunk) end
         ) do
      {:ok, options} ->
        SessionIO.push_router_trace(
          agent,
          "ACP answer choices generated from MCP question"
        )

        options

      {:error, reason} ->
        SessionIO.push_router_trace(
          agent,
          "ACP answer choices unavailable: #{inspect(reason)}"
        )

        []
    end
  end

  defp refine_user_answer(agent, st, user_text) do
    if InterviewAnswerRefiner.needs_refine?(user_text) do
      refine_live_user_answer(agent, st, user_text)
    else
      user_text
    end
  end

  defp refine_live_user_answer(agent, st, user_text) do
    original_question = get_interview_question(agent)

    payload =
      InterviewAnswerRefiner.payload(user_text,
        question: original_question || InterviewResponse.clean_markdown(user_text)
      )

    prompt = InterviewAnswerRefiner.refine_question(payload)

    event =
      InterviewWonderPrompt.event(
        st.parent_call_id,
        st.round,
        prompt,
        InterviewAnswerRefiner.refine_options()
      )

    SessionIO.push_router_trace(agent, "refine gate: preserving user answer structure")
    SessionIO.enqueue(agent, event, st.callbacks)

    case LoopBindingInterviewAwaiter.await(agent, st.parent_call_id, prompt, event_options(event)) do
      {:done, _text} ->
        payload

      {:answer, choice} ->
        case InterviewAnswerRefiner.apply_refine_choice(payload, choice, user_text) do
          {:send, refined_payload} ->
            refined_payload

          {:collect_more, followup_prompt} ->
            collect_refine_followup(agent, st, followup_prompt, user_text)
        end
    end
  end

  defp collect_refine_followup(agent, st, prompt, original_answer) do
    options = []
    event = InterviewWonderPrompt.event(st.parent_call_id, st.round, prompt, options)
    maybe_enqueue_wonder_event(agent, event, options, st.callbacks)

    case LoopBindingInterviewAwaiter.await(agent, st.parent_call_id, prompt, options) do
      {:done, _text} -> InterviewAnswerRefiner.payload(original_answer)
      {:answer, text} -> InterviewAnswerRefiner.payload(original_answer <> "\n" <> text)
    end
  end

  defp get_interview_question(agent) do
    Agent.get(agent, fn state ->
      state
      |> Map.get(:interview, %{})
      |> Map.get(:question)
    end)
  end

  defp max_context_chars(meta) do
    case InterviewResponse.meta_value(meta, "max_chars") do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _rest} when parsed > 0 -> parsed
          _other -> 1_200
        end

      _other ->
        1_200
    end
  end

  defp followup(agent, st, answer_text, new_streak) do
    if cancelled?(agent, st.parent_call_id) do
      :ok
    else
      followup_live(agent, st, answer_text, new_streak)
    end
  end

  defp maybe_poll_waiting_status(agent, %{session_id: session_id} = st)
       when is_binary(session_id) and session_id != "" do
    if Map.get(st, :status_poll_count, 0) < Map.get(st, :max_status_polls, 0) do
      poll_waiting_status(agent, st)
    else
      fail_exhausted_status_polling(agent, st)
    end
  end

  defp maybe_poll_waiting_status(_agent, _st), do: :ok

  defp poll_waiting_status(agent, st) do
    poll_count = Map.get(st, :status_poll_count, 0) + 1

    case InterviewWorkflowInvocation.build_resume_request_payload(st.session_id,
           request_id: st.parent_call_id <> "-status-" <> Integer.to_string(poll_count),
           mcp_tool: Map.get(st, :mcp_tool)
         ) do
      {:ok, payload} ->
        SessionIO.push_router_trace(
          agent,
          "status payload: polling interview session #{poll_count}"
        )

        sleep_status_poll_delay(st)
        interview_round(agent, %{st | payload: payload, status_poll_count: poll_count})

      {:error, reason} ->
        enqueue_failure(agent, st, {:resume_payload_failed, reason})
        :ok
    end
  end

  defp sleep_status_poll_delay(st) do
    delay_ms =
      st
      |> Map.get(:status_poll_delay_ms, 1_000)
      |> min(5_000)
      |> max(0)

    if delay_ms > 0, do: Process.sleep(delay_ms)
  end

  defp fail_exhausted_status_polling(agent, st) do
    SessionIO.push_router_trace(agent, "status payload: real question was not produced")

    enqueue_failure(
      agent,
      st,
      {:interview_question_unavailable,
       "Ouroboros returned delegated status payloads instead of an inline Socratic Interview question"}
    )
  end

  defp followup_live(agent, st, answer_text, new_streak) do
    case InterviewWorkflowInvocation.build_followup_request_payload(
           st.session_id,
           answer_text,
           request_id: st.parent_call_id <> "-r" <> Integer.to_string(st.round),
           mcp_tool: Map.get(st, :mcp_tool)
         ) do
      {:ok, payload} ->
        interview_round(agent, %{
          st
          | payload: payload,
            round: st.round + 1,
            status_poll_count: 0,
            streak: new_streak
        })

      {:error, reason} ->
        enqueue_failure(
          agent,
          st,
          {:followup_payload_failed, reason}
        )

        :ok
    end
  end

  defp enqueue_failure(
         agent,
         %{parent_call_id: parent_call_id, callbacks: callbacks} = st,
         reason
       ) do
    SessionIO.enqueue_failure(agent, parent_call_id, reason, callbacks,
      run_id: st.workflow_run_id
    )
  end

  defp enqueue_failure(agent, parent_call_id, reason, callbacks) do
    SessionIO.enqueue_failure(agent, parent_call_id, reason, callbacks,
      run_id: "workflow-run:" <> parent_call_id
    )
  end
end
