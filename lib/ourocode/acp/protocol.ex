defmodule Ourocode.Acp.Protocol do
  @moduledoc """
  Pure JSON-RPC 2.0 codec for the Agent Client Protocol (ACP).

  ACP frames are UTF-8 JSON-RPC messages delimited by newlines on stdio
  (https://agentclientprotocol.com/protocol/transports). This module owns
  decoding incoming frames and building outgoing result/error/notification
  frames; the stdio loop and session logic live in `Ourocode.Acp.Server`.
  """

  alias Ourocode.Json

  @protocol_version 1

  @type incoming ::
          {:request, term(), String.t(), map()}
          | {:notification, String.t(), map()}
          | {:invalid, term()}

  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "Decodes one newline-delimited JSON-RPC frame."
  @spec decode(String.t()) :: incoming()
  def decode(line) when is_binary(line) do
    case Json.decode(String.trim(line)) do
      {:ok, %{"jsonrpc" => "2.0", "method" => method} = frame} when is_binary(method) ->
        params =
          case Map.get(frame, "params") do
            %{} = params -> params
            _other -> %{}
          end

        case Map.fetch(frame, "id") do
          {:ok, id} -> {:request, id, method, params}
          :error -> {:notification, method, params}
        end

      {:ok, %{"id" => id}} ->
        {:invalid, id}

      _other ->
        {:invalid, nil}
    end
  end

  @doc "Encodes a successful response frame."
  @spec result(term(), map()) :: String.t()
  def result(id, result) when is_map(result) do
    encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  @doc "Encodes an error response frame."
  @spec error(term(), integer(), String.t()) :: String.t()
  def error(id, code, message) when is_integer(code) and is_binary(message) do
    encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  @doc "Encodes a one-way notification frame."
  @spec notification(String.t(), map()) :: String.t()
  def notification(method, params) when is_binary(method) and is_map(params) do
    encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  @doc "The `session/update` frame carrying one streamed agent text chunk."
  @spec agent_message_chunk(String.t(), String.t()) :: String.t()
  def agent_message_chunk(session_id, text) do
    notification("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      }
    })
  end

  @doc "The `initialize` result advertising ourocode's baseline capabilities."
  @spec initialize_result(String.t()) :: map()
  def initialize_result(version) when is_binary(version) do
    %{
      "protocolVersion" => @protocol_version,
      "agentCapabilities" => %{
        "loadSession" => false,
        "promptCapabilities" => %{
          "image" => false,
          "audio" => false,
          "embeddedContext" => false
        }
      },
      "agentInfo" => %{"name" => "ourocode", "title" => "Ourocode", "version" => version},
      "authMethods" => []
    }
  end

  @doc """
  Joins the text content blocks of a `session/prompt` request. All Agents
  MUST support text blocks; other block types are not advertised in our
  prompt capabilities and are ignored if sent anyway.
  """
  @spec prompt_text(map()) :: String.t()
  def prompt_text(%{"prompt" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("\n")
  end

  def prompt_text(_params), do: ""

  # Frames must not contain embedded newlines; the JSON encoder is compact
  # and escapes control characters, so encoding is enough.
  defp encode!(frame), do: frame |> Json.encode!() |> IO.iodata_to_binary()
end
