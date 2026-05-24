defmodule Ourocode.Provider.Codex.Client do
  @moduledoc """
  Streams a main-session turn through the ChatGPT Codex Responses endpoint.

  Uses the OAuth access token from `Ourocode.Provider.Codex` and the same
  `backend-api/codex/responses` endpoint + OpenAI Responses API shape that
  Codex CLI / opencode use. Streaming is done with `:httpc` async delivery so
  no extra dependency is needed; the SSE frame parser is pure and unit-tested.
  """

  alias Ourocode.Json
  alias Ourocode.Provider.Codex
  alias Ourocode.Provider.Codex.Responses

  @endpoint "https://chatgpt.com/backend-api/codex/responses"
  @default_model "gpt-5.3-codex"
  @instructions "You are ourocode, a terminal-native engineering agent. Be concise and precise."

  @doc """
  Streams `prompt`, invoking `on_chunk.(text)` for each output delta.

  Returns `{:ok, full_text}` on completion, `{:error, :not_signed_in}` when
  there is no Codex session, or `{:error, reason}` on a transport/API failure.
  """
  @spec stream(String.t(), keyword(), (String.t() -> any())) ::
          {:ok, String.t()} | {:error, term()}
  def stream(prompt, opts \\ [], on_chunk) when is_binary(prompt) and is_function(on_chunk, 1) do
    case Codex.authorization() do
      {:ok, %{access: access, account_id: account_id}} ->
        session_id = Keyword.get(opts, :session_id, "ourocode-main")
        model = Keyword.get(opts, :model, @default_model)
        body = request_body(prompt, model, Keyword.get(opts, :instructions, @instructions))
        headers = httpc_headers(Codex.api_headers(access, account_id, session_id))

        do_stream(headers, body, on_chunk)

      :error ->
        {:error, :not_signed_in}
    end
  end

  @doc """
  Builds the OpenAI Responses API request body for a single user turn.
  """
  @spec request_body(String.t(), String.t(), String.t()) :: map()
  defdelegate request_body(prompt, model, instructions), to: Responses

  @doc """
  Parses accumulated SSE bytes into `{events, rest}`.

  `events` are decoded JSON maps from `data:` lines (excluding the `[DONE]`
  sentinel); `rest` is an unterminated trailing frame for the next chunk.
  """
  @spec parse_sse(binary()) :: {[map()], binary()}
  defdelegate parse_sse(buffer), to: Responses

  @doc """
  Extracts the streamed text delta from a Responses API event, if any.
  """
  @spec text_delta(map()) :: String.t() | nil
  defdelegate text_delta(event), to: Responses

  @doc "True for the terminal Responses stream events."
  @spec terminal?(map()) :: boolean()
  defdelegate terminal?(event), to: Responses

  # --- internals -----------------------------------------------------------

  defp do_stream(headers, body_map, on_chunk) do
    _ = Application.ensure_all_started(:ssl)
    _ = Application.ensure_all_started(:inets)
    body = body_map |> Json.encode!() |> IO.iodata_to_binary()

    request =
      {String.to_charlist(@endpoint), headers, ~c"application/json", body}

    case :httpc.request(
           :post,
           request,
           [timeout: 120_000, connect_timeout: 20_000],
           sync: false,
           stream: :self,
           body_format: :binary
         ) do
      {:ok, request_id} ->
        receive_stream(request_id, "", [], on_chunk)

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp receive_stream(request_id, buffer, acc, on_chunk) do
    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        receive_stream(request_id, buffer, acc, on_chunk)

      {:http, {^request_id, :stream, chunk}} ->
        {events, rest} = Responses.parse_sse(buffer <> chunk)
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
    cond do
      delta = Responses.text_delta(event) ->
        on_chunk.(delta)
        [delta | acc]

      Responses.terminal?(event) ->
        acc

      true ->
        acc
    end
  end

  defp httpc_headers(headers) do
    Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 300)
  defp truncate(_body), do: ""
end
