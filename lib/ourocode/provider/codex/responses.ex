defmodule Ourocode.Provider.Codex.Responses do
  @moduledoc """
  Pure helpers for the Codex Responses API request and event stream.
  """

  alias Ourocode.Json

  @doc """
  Builds the OpenAI Responses API request body for a single user turn.
  """
  @spec request_body(String.t(), String.t(), String.t()) :: map()
  def request_body(prompt, model, instructions) do
    %{
      "model" => model,
      "instructions" => instructions,
      "input" => [
        %{
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => prompt}]
        }
      ],
      "stream" => true,
      "store" => false
    }
  end

  @doc """
  Parses accumulated SSE bytes into `{events, rest}`.

  `events` are decoded JSON maps from `data:` lines (excluding the `[DONE]`
  sentinel); `rest` is an unterminated trailing frame for the next chunk.
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

  @doc """
  Extracts the streamed text delta from a Responses API event, if any.
  """
  @spec text_delta(map()) :: String.t() | nil
  def text_delta(%{"type" => "response.output_text.delta", "delta" => delta})
      when is_binary(delta),
      do: delta

  def text_delta(_event), do: nil

  @doc "True for the terminal Responses stream events."
  @spec terminal?(map()) :: boolean()
  def terminal?(%{"type" => type}),
    do: type in ["response.completed", "response.incomplete", "response.failed"]

  def terminal?(_event), do: false

  defp decode_frame(frame) do
    frame
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(fn line ->
      case String.split(String.trim_leading(line), ":", parts: 2) do
        ["data", value] ->
          decode_data_line(value)

        _ ->
          []
      end
    end)
  end

  defp decode_data_line(value) do
    value = String.trim(value)

    if value == "" or value == "[DONE]" do
      []
    else
      case Json.decode(value) do
        {:ok, %{} = map} -> [map]
        _ -> []
      end
    end
  end
end
