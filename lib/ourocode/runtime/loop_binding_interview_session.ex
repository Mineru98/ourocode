defmodule Ourocode.Runtime.LoopBindingInterviewSession do
  @moduledoc """
  Runs the live interview relay used by terminal loop bindings.
  """

  alias Ourocode.Runtime.{
    InterviewEvents,
    InterviewProgress,
    InterviewOptionGenerator,
    LoopBindingQuestionRouter,
    InterviewResponse,
    InterviewState,
    InterviewWonderPrompt,
    InterviewWorkflowInvocation,
    LoopBindingInterviewAwaiter,
    LoopBindingInterviewRound,
    LoopBindingRouterDecision,
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
    if optimistic_first_round?(st) do
      optimistic_interview_round(agent, st)
    else
      regular_interview_round(agent, st)
    end
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

  defp optimistic_interview_round(agent, st) do
    prompt = optimistic_prompt(st.payload)
    options = generated_question_options(agent, st, prompt, [])
    event = InterviewWonderPrompt.event(st.parent_call_id, st.round, prompt, options)

    SessionIO.push_dialogue(agent, :main, "→ asking you: " <> prompt)
    SessionIO.enqueue(agent, event, st.callbacks)

    waiter = self()

    Agent.update(agent, fn state ->
      LoopBindingInterviewAwaiter.wait_state(
        state,
        st.parent_call_id,
        prompt,
        waiter,
        event_options(event)
      )
    end)

    case take_pending_interview_answer(agent) do
      nil ->
        :ok

      text ->
        send(waiter, {:interview_answer, text})
    end

    task = Task.async(fn -> st.pcf.(st.payload) end)

    receive do
      {:interview_answer, text} ->
        _ = take_pending_interview_answer(agent)

        handle_optimistic_answer(
          agent,
          st,
          task,
          LoopBindingInterviewAwaiter.classify_answer(text)
        )

      {ref, result} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])

        case take_pending_interview_answer(agent) do
          nil -> handle_round_action(agent, st, result)
          text -> relay_optimistic_answer(agent, st, result, text)
        end

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        enqueue_failure(agent, st, {:transport_failed, reason})
        :ok
    after
      120_000 ->
        Task.shutdown(task, :brutal_kill)

        enqueue_failure(
          agent,
          st,
          :interview_initial_question_timeout
        )

        :ok
    end
  end

  defp handle_optimistic_answer(agent, st, task, {:done, text}) do
    Task.shutdown(task, :brutal_kill)
    SessionIO.push_dialogue(agent, :user, text)

    SessionIO.enqueue_complete(agent, st.parent_call_id, :user_done, st.callbacks,
      run_id: st.workflow_run_id
    )

    :ok
  end

  defp handle_optimistic_answer(agent, st, task, {:answer, user_text}) do
    InterviewProgress.mark_answer_sync(agent, "opening interview session to send answer")

    case await_task_result(task) do
      {:ok, result} ->
        unless cancelled?(agent, st.parent_call_id) do
          relay_optimistic_answer(agent, st, result, user_text)
        end

      {:error, reason} ->
        unless cancelled?(agent, st.parent_call_id) do
          enqueue_failure(agent, st, {:transport_failed, reason})
        end

        :ok
    end
  end

  defp await_task_result(task) do
    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        {:ok, result}

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        {:error, reason}
    after
      120_000 ->
        Task.shutdown(task, :brutal_kill)
        {:error, :interview_initial_question_timeout}
    end
  end

  defp take_pending_interview_answer(agent) do
    Agent.get_and_update(agent, fn state ->
      {Map.get(state, :pending_interview_answer), Map.put(state, :pending_interview_answer, nil)}
    end)
  end

  defp relay_optimistic_answer(agent, st, result, user_text) do
    if cancelled?(agent, st.parent_call_id) do
      :ok
    else
      relay_live_optimistic_answer(agent, st, result, user_text)
    end
  end

  defp relay_live_optimistic_answer(agent, st, result, user_text) do
    case LoopBindingInterviewRound.action(result, st.session_id) do
      {:question, _question, _text, _meta, session_id} ->
        SessionIO.push_dialogue(agent, :user, user_text)
        InterviewProgress.mark_answer_sync(agent, "answer sent - generating next question")

        followup(
          agent,
          %{st | session_id: session_id, user_routed?: true},
          LoopBindingInterviewText.ensure_user_prefix(user_text),
          0
        )

      {:complete, text, meta, session_id} ->
        SessionIO.merge_interview(agent, st.parent_call_id, text, meta, session_id)
        SessionIO.push_dialogue(agent, :user, user_text)

        SessionIO.enqueue_complete(agent, st.parent_call_id, :seed_ready, st.callbacks,
          run_id: st.workflow_run_id
        )

        :ok

      {:server_error, message, session_id} ->
        enqueue_server_error(agent, st.parent_call_id, message, session_id, st.callbacks)
        :ok

      :missing_session_id ->
        enqueue_failure(agent, st, :interview_session_id_missing)
        :ok

      {:transport_failed, reason} ->
        enqueue_failure(agent, st, {:transport_failed, reason})
        :ok
    end
  end

  defp optimistic_first_round?(%{round: 1, session_id: nil, payload: payload}) do
    payload
    |> LoopBindingInterviewText.initial_context_from_payload()
    |> String.trim()
    |> String.downcase()
    |> String.starts_with?("ooo pm")
  end

  defp optimistic_first_round?(_st), do: false

  defp optimistic_prompt(payload) do
    context =
      payload
      |> LoopBindingInterviewText.initial_context_from_payload()
      |> String.trim()

    goal =
      context
      |> String.replace(~r/\Aooo\s+pm\s*/iu, "")
      |> String.trim()

    if goal == "" do
      "What outcome should this PM interview produce?"
    else
      "What outcome should this PM interview produce for #{goal}?"
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
        route_question_with_router(agent, st, question)
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

  defp route_question_with_router(agent, st, question) do
    ctx = %{project_dir: st.project_dir, streak: st.streak}
    on_trace = fn line -> SessionIO.push_router_trace(agent, line) end
    on_reason = fn chunk -> SessionIO.push_reasoning(agent, chunk) end

    question
    |> LoopBindingQuestionRouter.decide(ctx, st.model, st.router_decision_timeout_ms,
      on_trace: on_trace,
      on_reason: on_reason
    )
    |> LoopBindingRouterDecision.action(question, st.streak)
    |> case do
      {:followup, payload_text, new_streak, dialogue_text} ->
        if cancelled?(agent, st.parent_call_id) do
          :ok
        else
          SessionIO.push_dialogue(agent, :main, dialogue_text)
          followup(agent, st, payload_text, new_streak)
        end

      {:ask_user, prompt, options, :leaked_prompt} ->
        if cancelled?(agent, st.parent_call_id) do
          :ok
        else
          SessionIO.push_router_trace(
            agent,
            "router: discarded echoed prompt and asked user"
          )

          ask_user(agent, st, prompt, options)
        end

      {:ask_user, prompt, options, :router} ->
        ask_user(agent, st, prompt, options)

      {:error, reason} ->
        unless cancelled?(agent, st.parent_call_id) do
          enqueue_failure(agent, st, {:router_failed, reason})
        end

        :ok
    end
  end

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

    SessionIO.enqueue(agent, event, st.callbacks)

    case LoopBindingInterviewAwaiter.await(agent, st.parent_call_id, prompt, event_options(event)) do
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
          SessionIO.push_dialogue(agent, :user, user_text)

          followup(
            agent,
            %{st | user_routed?: true},
            LoopBindingInterviewText.ensure_user_prefix(user_text),
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

  defp generated_question_options(_agent, _st, _prompt, [_first | _rest] = options), do: options

  defp generated_question_options(agent, st, prompt, _options) do
    timeout_ms = min(max(st.router_decision_timeout_ms, 250), 1_500)

    case InterviewOptionGenerator.generate(prompt, st.model, timeout_ms: timeout_ms) do
      {:ok, options} ->
        SessionIO.push_router_trace(
          agent,
          "main session generated #{length(options)} answer choices"
        )

        options

      {:error, reason} ->
        SessionIO.push_router_trace(
          agent,
          "answer choices fallback: #{inspect(reason)}"
        )

        []
    end
  end

  defp followup(agent, st, answer_text, new_streak) do
    if cancelled?(agent, st.parent_call_id) do
      :ok
    else
      followup_live(agent, st, answer_text, new_streak)
    end
  end

  defp followup_live(agent, st, answer_text, new_streak) do
    case InterviewWorkflowInvocation.build_followup_request_payload(
           st.session_id,
           answer_text,
           request_id: st.parent_call_id <> "-r" <> Integer.to_string(st.round)
         ) do
      {:ok, payload} ->
        interview_round(agent, %{
          st
          | payload: payload,
            round: st.round + 1,
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
