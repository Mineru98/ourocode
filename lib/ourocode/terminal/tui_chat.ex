defmodule Ourocode.Terminal.TuiChat do
  @moduledoc false

  alias Ourocode.Model
  alias Ourocode.Terminal.{InterviewHandoff, InterviewPanel, TuiInteraction, TuiState}

  @spec chat(
          String.t(),
          map(),
          pid(),
          pid(),
          pos_integer(),
          pos_integer(),
          function(),
          function()
        ) ::
          :ok
  def chat(prompt, result, output, state, cols, rows, active_model, redraw)
      when is_function(active_model, 1) and is_function(redraw, 6) do
    model = active_model.(state)

    cond do
      model == nil ->
        log(output, "you> #{prompt}")
        log(output, "No model available. /model to pick one, /login for ChatGPT.")
        redraw.(result, output, state, "", cols, rows)

      Model.needs_auth?(model) ->
        log(output, "you> #{prompt}")
        log(output, "#{model.label} needs sign-in. /login for ChatGPT, or /model.")
        redraw.(result, output, state, "", cols, rows)

      true ->
        stream_chat(model, prompt, result, output, state, cols, rows, redraw)
    end
  end

  defp stream_chat(model, prompt, result, output, state, cols, rows, redraw) do
    log(output, "you> #{prompt}")
    IO.write(output, "ourocode> ")
    TuiState.set_streaming(state, true)
    redraw.(result, output, state, "", cols, rows)

    on_chunk = fn chunk ->
      IO.write(output, chunk)
      redraw.(result, output, state, "", cols, rows)
    end

    model_prompt = maybe_paused_interview_prompt(result, prompt)

    case Model.stream(model, model_prompt, [session_id: session_id(result)], on_chunk) do
      {:ok, full} ->
        IO.write(output, "\n")
        maybe_handoff_paused_interview_answer(result, output, full)

      {:error, :not_signed_in} ->
        log(output, "\nNot connected. /login for ChatGPT.")

      {:error, reason} ->
        log(output, "\n#{model.label} error: #{inspect(reason)}")
    end

    TuiState.set_streaming(state, false)
    redraw.(result, output, state, "", cols, rows)
  end

  defp maybe_paused_interview_prompt(result, prompt) do
    if TuiInteraction.paused?(result) and
         (TuiInteraction.interview_active?(result) or TuiInteraction.wonder_active?(result)) do
      InterviewHandoff.prompt(paused_interview_question(result), prompt)
    else
      prompt
    end
  end

  defp paused_interview_question(result) do
    cond do
      detection = TuiInteraction.wonder_detection(result) ->
        detection
        |> InterviewPanel.wonder_questions()
        |> List.first()
        |> case do
          %{} = question -> InterviewPanel.md_text(Map.get(question, :question, ""))
          _none -> "unknown"
        end

      interview = TuiInteraction.interview_state(result) ->
        InterviewPanel.md_text(Map.get(interview, :question, "unknown"))

      true ->
        "unknown"
    end
  end

  defp maybe_handoff_paused_interview_answer(result, output, full) do
    with true <- TuiInteraction.paused?(result),
         true <- TuiInteraction.interview_active?(result) or TuiInteraction.wonder_active?(result),
         answer when is_binary(answer) <- InterviewHandoff.extract_answer(full),
         send when is_function(send, 1) <- Map.get(result, :interview_answer),
         {:ok, _text} <- send.(answer) do
      log(output, "-- interview answered from main session")
    else
      _other -> :ok
    end
  end

  defp session_id(result) do
    get_in(result, [:runtime, :session_id]) || get_in(result, [:context, :runtime_session_id]) ||
      "ourocode-main"
  end

  defp log(output, text), do: IO.puts(output, text)
end
