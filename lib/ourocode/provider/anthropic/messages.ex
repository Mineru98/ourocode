defmodule Ourocode.Provider.Anthropic.Messages do
  @moduledoc """
  Pure helpers for the Anthropic Messages API request and SSE stream.

  These mirror the shapes a Claude Pro/Max OAuth session uses: the request
  carries the Claude Code system instruction as the first system block (the
  subscription inference endpoint requires it), and the stream is parsed
  from `content_block_delta` text events.
  """

  alias Ourocode.Json

  # Required first system block for subscription (OAuth) inference. Without
  # it `/v1/messages` rejects an OAuth bearer token.
  @claude_code_system "You are a Claude agent, built on Anthropic's Claude Agent SDK."

  @doc "The mandatory Claude Code system instruction string."
  @spec claude_code_system() :: String.t()
  def claude_code_system, do: @claude_code_system

  @doc """
  Builds the `/v1/messages` request body for a single streamed turn. `input`
  is the alternating user/assistant message list (history + current message);
  `extra_system` is any caller system text placed after the required block.
  """
  @spec request_body([map()], String.t(), pos_integer(), String.t() | nil) :: map()
  def request_body(input, model, max_tokens, extra_system \\ nil)
      when is_list(input) and is_binary(model) and is_integer(max_tokens) do
    system =
      [%{"type" => "text", "text" => @claude_code_system}] ++
        case extra_system do
          text when is_binary(text) and text != "" ->
            [%{"type" => "text", "text" => text}]

          _none ->
            []
        end

    %{
      "model" => model,
      "max_tokens" => max_tokens,
      "system" => system,
      "messages" => input,
      "stream" => true
    }
  end

  @doc "Builds the alternating user/assistant message list from a conversation."
  @spec messages([{String.t(), String.t()}], String.t()) :: [map()]
  def messages(turns, prompt) when is_list(turns) and is_binary(prompt) do
    history =
      Enum.flat_map(turns, fn {user, assistant} ->
        [message("user", user), message("assistant", assistant)]
      end)

    history ++ [message("user", prompt)]
  end

  defp message(role, text),
    do: %{"role" => role, "content" => [%{"type" => "text", "text" => text}]}

  @doc """
  Parses accumulated SSE bytes into `{events, rest}`. Anthropic frames are
  `event:`/`data:` line pairs separated by blank lines; only the JSON from
  `data:` lines is decoded.
  """
  @spec parse_sse(binary()) :: {[map()], binary()}
  def parse_sse(buffer) when is_binary(buffer) do
    case String.split(buffer, ~r/\r?\n\r?\n/) do
      [single] ->
        {[], single}

      parts ->
        {complete, [rest]} = Enum.split(parts, -1)
        {Enum.flat_map(complete, &decode_frame/1), rest}
    end
  end

  @doc "Extracts the streamed text delta from a Messages stream event, if any."
  @spec text_delta(map()) :: String.t() | nil
  def text_delta(%{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}})
      when is_binary(text),
      do: text

  def text_delta(_event), do: nil

  @doc "True for the terminal Messages stream events."
  @spec terminal?(map()) :: boolean()
  def terminal?(%{"type" => type}), do: type in ["message_stop", "error"]
  def terminal?(_event), do: false

  defp decode_frame(frame) do
    frame
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(fn line ->
      case String.split(String.trim_leading(line), ":", parts: 2) do
        ["data", value] -> decode_data_line(value)
        _other -> []
      end
    end)
  end

  defp decode_data_line(value) do
    case String.trim(value) do
      "" -> []
      trimmed -> case Json.decode(trimmed), do: ({:ok, %{} = map} -> [map]; _ -> [])
    end
  end
end
