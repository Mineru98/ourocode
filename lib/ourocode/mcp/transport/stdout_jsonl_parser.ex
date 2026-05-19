defmodule Ourocode.MCP.Transport.StdoutJsonlParser do
  @moduledoc """
  Decodes stdout JSONL records from external MCP helper processes.

  Runtime helpers may write human-readable logs to stdout alongside JSON-RPC
  records. This parser treats stdout as a tolerant JSONL stream: valid JSON
  object lines are returned and malformed, blank, or non-JSON lines are ignored.
  """

  @type decoded_record :: map()
  @type raw_protocol_message :: Ourocode.MCP.Transport.RawProtocolMessage.t()
  @type parse_error :: %{
          required(:line) => String.t(),
          required(:reason) => term()
        }
  @type codex_external_ids :: %{
          optional(:native_session_id) => String.t(),
          optional(:session_id) => String.t(),
          optional(:thread_id) => String.t(),
          optional(:input_session_id) => String.t(),
          optional(:input_call_id) => String.t(),
          optional(:input) => map()
        }

  @doc """
  Parses a single stdout line.

  Only JSON object records are accepted because MCP stdout records must be
  structured messages. Arrays, scalars, malformed JSON, and plain logs are
  ignored.
  """
  @spec parse_line(String.t(), module()) :: {:ok, decoded_record()} | :ignore
  def parse_line(line, codec \\ Ourocode.Json) when is_binary(line) do
    line
    |> String.trim()
    |> decode_trimmed(codec, :ignore_errors)
  end

  @doc """
  Parses a JSONL stdout chunk or full buffer into valid decoded records.
  """
  @spec parse(String.t(), module()) :: [decoded_record()]
  def parse(jsonl, codec \\ Ourocode.Json) when is_binary(jsonl) do
    jsonl
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.flat_map(fn line ->
      case parse_line(line, codec) do
        {:ok, record} -> [record]
        :ignore -> []
      end
    end)
  end

  @doc """
  Parses a single stdout line into a typed raw JSON-RPC protocol message.

  Non-JSON, malformed, blank, array, and scalar lines are ignored. JSON object
  lines are preserved as raw payloads and classified as requests,
  notifications, responses, error responses, or unknown objects.
  """
  @spec parse_protocol_line(String.t(), module()) :: {:ok, raw_protocol_message()} | :ignore
  def parse_protocol_line(line, codec \\ Ourocode.Json) when is_binary(line) do
    case parse_protocol_line_detailed(line, codec) do
      {:ok, message} -> {:ok, message}
      :ignore -> :ignore
      {:error, _error} -> :ignore
    end
  end

  @doc """
  Parses a single stdout line into a typed raw JSON-RPC protocol message while
  preserving malformed JSON errors for transport-level normalization.

  Plain helper logs are still ignored. JSON-looking lines that fail decoding
  are returned as errors so a transport can emit a no-loss decode failure event.
  """
  @spec parse_protocol_line_detailed(String.t(), module()) ::
          {:ok, raw_protocol_message()} | :ignore | {:error, parse_error()}
  def parse_protocol_line_detailed(line, codec \\ Ourocode.Json) when is_binary(line) do
    trimmed = String.trim(line)

    case decode_trimmed(trimmed, codec, :preserve_errors) do
      {:ok, record} ->
        {:ok, Ourocode.MCP.Transport.RawProtocolMessage.from_decoded(record, trimmed)}

      {:error, reason} ->
        {:error, %{line: trimmed, reason: reason}}

      :ignore ->
        :ignore
    end
  end

  @doc """
  Parses a JSONL stdout chunk or full buffer into typed raw protocol messages.
  """
  @spec parse_protocol(String.t(), module()) :: [raw_protocol_message()]
  def parse_protocol(jsonl, codec \\ Ourocode.Json) when is_binary(jsonl) do
    jsonl
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.flat_map(fn line ->
      case parse_protocol_line(line, codec) do
        {:ok, message} -> [message]
        :ignore -> []
      end
    end)
  end

  @doc """
  Parses one Codex stdout JSONL line and extracts supported runtime IDs.

  Codex JSONL output appears in a few envelope shapes depending on the command
  and version. This function keeps the decoded record unchanged while returning
  normalized runtime IDs found at the top level or in supported event
  containers such as `msg`, `event`, `payload`, `data`, `params`, `result`,
  and `input`.
  """
  @spec parse_codex_line(String.t(), module()) ::
          {:ok, decoded_record(), codex_external_ids()} | :ignore
  def parse_codex_line(line, codec \\ Ourocode.Json) when is_binary(line) do
    case parse_line(line, codec) do
      {:ok, record} -> {:ok, record, extract_codex_external_ids(record)}
      :ignore -> :ignore
    end
  end

  @doc """
  Extracts normalized Codex runtime IDs from a decoded stdout JSONL record.
  """
  @spec extract_codex_external_ids(decoded_record()) :: codex_external_ids()
  def extract_codex_external_ids(record) when is_map(record) do
    Ourocode.MCP.RuntimeEventParser.extract_external_ids(record)
  end

  defp decode_trimmed("", _codec, _error_mode), do: :ignore

  defp decode_trimmed(line, codec, error_mode) do
    case codec.decode(line) do
      {:ok, record} when is_map(record) -> {:ok, record}
      {:ok, _other} -> :ignore
      {:error, reason} -> decode_error_or_ignore(line, reason, error_mode)
    end
  rescue
    exception -> decode_error_or_ignore(line, Exception.message(exception), error_mode)
  end

  defp decode_error_or_ignore(line, reason, :preserve_errors) do
    if json_like?(line) do
      {:error, reason}
    else
      :ignore
    end
  end

  defp decode_error_or_ignore(_line, _reason, :ignore_errors), do: :ignore

  defp json_like?("{" <> _rest), do: true
  defp json_like?("[" <> _rest), do: true
  defp json_like?(_line), do: false
end
