defmodule Ourocode.Runtime.InterviewTurn do
  @moduledoc """
  Classifies plain-text Ouroboros interview MCP responses.
  """

  alias Ourocode.Runtime.InterviewResponse

  @empty_response_message "empty response from the MCP question generator"
  @complete_re ~r/Interview completed|Ready for Seed generation|📍\s*Next:\s*ooo seed|\booo seed\b|seed-ready/i
  @server_failure_re ~r/Question generation failed|question generation failed after retries|MCP is having trouble/i

  @spec classify_response(term()) ::
          :complete
          | {:question, String.t()}
          | {:server_error, String.t()}
          | {:waiting, String.t()}
  def classify_response(text) when is_binary(text) do
    cond do
      String.trim(text) == "" ->
        {:server_error, @empty_response_message}

      delegated_status_payload?(text) ->
        {:waiting, delegated_status_message(text)}

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

  defp delegated_status_payload?(text) do
    case decode_json_object(text) do
      {:ok, body} ->
        delegated_status?(body) or pending_status?(body) or agent_task_status?(body)

      :error ->
        false
    end
  end

  defp delegated_status_message(text) do
    case decode_json_object(text) do
      {:ok, body} ->
        cond do
          agent_task_status?(body) ->
            agent_task_status_message(body)

          true ->
            body
            |> status_message_field()
            |> case do
              action when is_binary(action) and action != "" ->
                action
                |> String.replace("_", " ")
                |> String.replace(~r/\s+/, " ")
                |> String.trim()
                |> String.slice(0, 160)

              _none ->
                "waiting for delegated interview session"
            end
        end

      :error ->
        "waiting for delegated interview session"
    end
  end

  defp delegated_status?(body) do
    normalize_token(field(body, "status")) in [
      "delegatedtosubagent",
      "delegatedtoplugin",
      "delegated"
    ]
  end

  defp pending_status?(body) do
    not is_nil(field(body, "next_action")) or
      not is_nil(field(body, "pending_question")) or
      not is_nil(field(body, "pendingquestion"))
  end

  defp agent_task_status?(body) do
    Enum.all?(["agent", "general", "context", "action"], &(not is_nil(field(body, &1))))
  end

  defp agent_task_status_message(body) do
    agent =
      body
      |> field("agent")
      |> case do
        value when is_binary(value) and value != "" -> value
        _none -> "Socratic Interview"
      end

    "starting #{agent}"
  end

  defp status_message_field(body) do
    field(body, "next_action") ||
      field(body, "nextaction") ||
      field(body, "action") ||
      field(body, "message")
  end

  defp decode_json_object(text) do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "{") do
      case Ourocode.Json.decode(trimmed) do
        {:ok, %{} = body} -> {:ok, body}
        _other -> :error
      end
    else
      :error
    end
  end

  defp field(body, wanted_key) when is_map(body) do
    wanted = normalize_token(wanted_key)

    Enum.find_value(body, fn {key, value} ->
      if normalize_token(key) == wanted, do: value
    end)
  end

  defp normalize_token(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "")
  end
end
