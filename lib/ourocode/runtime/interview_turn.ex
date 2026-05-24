defmodule Ourocode.Runtime.InterviewTurn do
  @moduledoc """
  Classifies plain-text Ouroboros interview MCP responses.
  """

  alias Ourocode.Runtime.InterviewResponse

  @empty_response_message "empty response from the MCP question generator"
  @complete_re ~r/Interview completed|Ready for Seed generation|📍\s*Next:\s*ooo seed|\booo seed\b|seed-ready/i
  @server_failure_re ~r/Question generation failed|question generation failed after retries|MCP is having trouble/i

  @spec classify_response(term()) ::
          :complete | {:question, String.t()} | {:server_error, String.t()}
  def classify_response(text) when is_binary(text) do
    cond do
      String.trim(text) == "" ->
        {:server_error, @empty_response_message}

      Regex.match?(@complete_re, text) ->
        :complete

      Regex.match?(@server_failure_re, text) ->
        {:server_error, server_failure_message(text)}

      true ->
        {:question, InterviewResponse.question_from(text)}
    end
  end

  def classify_response(_text), do: {:server_error, @empty_response_message}

  @spec server_failure_message(String.t()) :: String.t()
  def server_failure_message(text) when is_binary(text) do
    text
    |> String.split(~r/\s*\.?\s*Session ID:|Resume with:/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 240)
  end
end
