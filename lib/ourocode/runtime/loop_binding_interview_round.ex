defmodule Ourocode.Runtime.LoopBindingInterviewRound do
  @moduledoc """
  Converts one parent-call interview result into a loop action.
  """

  alias Ourocode.Runtime.{InterviewResponse, InterviewTurn}

  @type action ::
          {:server_error, String.t(), String.t() | nil}
          | {:waiting, String.t(), map(), String.t() | nil}
          | {:summarize_initial_context, map(), String.t()}
          | {:complete, String.t(), map(), String.t() | nil}
          | {:question, String.t(), String.t(), map(), String.t()}
          | :missing_session_id
          | {:transport_failed, term()}

  @spec action({:ok, term()} | {:error, term()}, String.t() | nil) :: action()
  def action({:error, reason}, _current_session_id), do: {:transport_failed, reason}

  def action({:ok, result}, current_session_id) do
    response = InterviewResponse.parent_response(result)
    text = InterviewResponse.text(response)
    meta = InterviewResponse.meta(response)
    session_id = InterviewResponse.extract_session_id(text, meta) || current_session_id

    cond do
      initial_context_too_large?(meta) and is_binary(session_id) ->
        {:summarize_initial_context, meta, session_id}

      initial_context_too_large?(meta) ->
        :missing_session_id

      true ->
        classify_text(text, meta, session_id)
    end
  end

  defp classify_text(text, meta, session_id) do
    case InterviewTurn.classify_response(text) do
      {:server_error, message} ->
        {:server_error, message, session_id}

      {:waiting, message} ->
        {:waiting, message, meta, session_id}

      :complete ->
        {:complete, text, meta, session_id}

      {:question, question} when is_binary(session_id) ->
        {:question, question, text, meta, session_id}

      {:question, _question} ->
        :missing_session_id
    end
  end

  defp initial_context_too_large?(meta) do
    InterviewResponse.meta_value(meta, "reason") == "initial_context_too_large"
  end
end
