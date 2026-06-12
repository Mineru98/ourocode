defmodule Ourocode.Provider.Anthropic.Client do
  @moduledoc """
  Streams a main-session turn through the Anthropic Messages endpoint using a
  Claude Pro/Max OAuth token.

  This is the direct-API path that lets `claude` answer without spawning the
  CLI on every turn. OAuth inference requires presenting Claude Code's
  identity: a bearer token, the `oauth-2025-04-20` beta, the claude-cli user
  agent, and the Claude Code system instruction as the first system block
  (handled in `Messages.request_body/4`).
  """

  alias Ourocode.Json
  alias Ourocode.Provider.Anthropic.Auth
  alias Ourocode.Provider.Anthropic.Messages

  @endpoint "https://api.anthropic.com/v1/messages"
  @default_model "claude-sonnet-4-6"
  @default_max_tokens 8_192
  @anthropic_version "2023-06-01"
  @beta "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14"
  @user_agent "claude-cli/1.0.0 (external, cli)"

  @doc """
  Streams `prompt`, invoking `on_chunk.(text)` for each output delta.

  Accepts `:input` (prepared multi-turn message list) or builds a single
  user turn from `prompt`. Returns `{:ok, full_text}`, `{:error,
  :not_signed_in}`, or `{:error, reason}`.
  """
  @spec stream(String.t(), keyword(), (String.t() -> any())) ::
          {:ok, String.t()} | {:error, term()}
  def stream(prompt, opts \\ [], on_chunk) when is_binary(prompt) and is_function(on_chunk, 1) do
    case Auth.authorization() do
      {:ok, access} ->
        model = Keyword.get(opts, :model, @default_model)
        max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

        input =
          case Keyword.get(opts, :input) do
            list when is_list(list) and list != [] -> list
            _none -> [%{"role" => "user", "content" => [%{"type" => "text", "text" => prompt}]}]
          end

        # The first system block must stay the Claude Code instruction for
        # OAuth inference; ourocode's identity follows as extra system text.
        body = Messages.request_body(input, model, max_tokens, Ourocode.Prompt.system())
        do_stream(access, body, on_chunk)

      :error ->
        {:error, :not_signed_in}
    end
  end

  @doc "Request headers presenting Claude Code's OAuth identity."
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(access) do
    [
      {"authorization", "Bearer " <> access},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"anthropic-version", @anthropic_version},
      {"anthropic-beta", @beta},
      {"anthropic-dangerous-direct-browser-access", "true"},
      {"user-agent", @user_agent},
      {"x-app", "cli"}
    ]
  end

  defp do_stream(access, body_map, on_chunk) do
    _ = Application.ensure_all_started(:ssl)
    _ = Application.ensure_all_started(:inets)
    body = body_map |> Json.encode!() |> IO.iodata_to_binary()
    headers = httpc_headers(headers(access))
    request = {String.to_charlist(@endpoint), headers, ~c"application/json", body}

    case :httpc.request(
           :post,
           request,
           [timeout: 120_000, connect_timeout: 20_000],
           sync: false,
           stream: :self,
           body_format: :binary
         ) do
      {:ok, request_id} -> receive_stream(request_id, "", [], on_chunk)
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  defp receive_stream(request_id, buffer, acc, on_chunk) do
    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        receive_stream(request_id, buffer, acc, on_chunk)

      {:http, {^request_id, :stream, chunk}} ->
        {events, rest} = Messages.parse_sse(buffer <> chunk)
        acc = Enum.reduce(events, acc, &handle_event(&1, &2, on_chunk))
        receive_stream(request_id, rest, acc, on_chunk)

      {:http, {^request_id, :stream_end, _headers}} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {:http, {^request_id, {{_v, status, _r}, _headers, resp_body}}} ->
        {:error, {:api_error, status, truncate(resp_body)}}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, {:http_error, reason}}
    after
      120_000 ->
        :httpc.cancel_request(request_id)
        {:error, :timeout}
    end
  end

  defp handle_event(event, acc, on_chunk) do
    case Messages.text_delta(event) do
      nil ->
        acc

      delta ->
        on_chunk.(delta)
        [delta | acc]
    end
  end

  defp httpc_headers(headers) do
    Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 300)
  defp truncate(_body), do: ""
end
