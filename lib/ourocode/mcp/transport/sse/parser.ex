defmodule Ourocode.MCP.Transport.SSE.Parser do
  @moduledoc """
  Incremental parser for `text/event-stream` frames.

  The parser accepts an arbitrary stream buffer, returns one parsed event for
  each complete frame separated by a blank line, and preserves any incomplete
  trailing bytes for the next transport read.
  """

  alias Ourocode.Json

  @type parsed_event :: map()

  @doc """
  Parses complete SSE frames from `buffer`.

  A frame is complete only when it is followed by a blank line. The returned
  `rest` must be appended to the next transport chunk before parsing again.
  Comment-only frames and frames without `data:` or valid `retry:` metadata
  are ignored. Frames with malformed JSON data return an error so callers can
  emit a transport decode failure instead of silently dropping the frame.
  """
  @spec parse_complete_frames(String.t(), module()) ::
          {:ok, [parsed_event()], String.t()} | {:error, term()}
  def parse_complete_frames(buffer, codec \\ Json) when is_binary(buffer) do
    {frames, rest} = split_complete_frames(buffer)

    frames
    |> Enum.reduce_while({:ok, []}, fn frame, {:ok, acc} ->
      case parse_frame(frame, codec) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events), rest}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Splits an SSE stream buffer into complete raw frames and incomplete rest.
  """
  @spec split_complete_frames(String.t()) :: {[String.t()], String.t()}
  def split_complete_frames(buffer) when is_binary(buffer) do
    case Regex.split(~r/\r?\n\r?\n/, buffer, include_captures: true) do
      [^buffer] ->
        {[], buffer}

      parts ->
        complete? = Regex.match?(~r/\r?\n\r?\n\z/, buffer)

        frames =
          parts
          |> Enum.reject(&Regex.match?(~r/\A\r?\n\r?\n\z/, &1))
          |> then(fn chunks ->
            if complete?, do: chunks, else: Enum.drop(chunks, -1)
          end)

        rest = if complete?, do: "", else: List.last(parts)
        {Enum.reject(frames, &(&1 == "")), rest}
    end
  end

  @doc """
  Parses one raw SSE frame.
  """
  @spec parse_frame(String.t(), module()) :: {:ok, parsed_event() | nil} | {:error, term()}
  def parse_frame(frame, codec \\ Json) when is_binary(frame) do
    fields =
      frame
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.trim_leading/1)
      |> Enum.reject(&String.starts_with?(&1, ":"))
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            put_field(acc, key, strip_sse_value_prefix(value))

          [key] ->
            put_field(acc, key, "")
        end
      end)

    case fields do
      %{"data" => data_lines} ->
        data = data_lines |> Enum.reverse() |> Enum.join("\n")

        with {:ok, decoded} <- codec.decode(data) do
          {:ok,
           fields
           |> Map.put("data", decoded)
           |> normalize_event_fields()
           |> put_retry_metadata()}
        end

      _ ->
        fields
        |> normalize_event_fields()
        |> put_retry_metadata()
        |> retry_metadata_event()
    end
  end

  defp put_field(fields, key, value) do
    Map.update(fields, String.trim(key), [value], &[value | &1])
  end

  defp normalize_event_fields(fields) do
    fields
    |> Map.update("event", "message", fn values ->
      values |> List.first() |> to_string()
    end)
    |> Map.update("id", nil, fn values -> values |> List.first() |> to_string() end)
  end

  defp put_retry_metadata(%{"retry" => values} = event) when is_list(values) do
    case parse_retry_delay_ms(List.first(values)) do
      {:ok, delay_ms} ->
        event
        |> Map.put("retry", delay_ms)
        |> Map.update("metadata", %{"reconnection_delay_ms" => delay_ms}, fn
          metadata when is_map(metadata) -> Map.put(metadata, "reconnection_delay_ms", delay_ms)
          _metadata -> %{"reconnection_delay_ms" => delay_ms}
        end)

      :ignore ->
        Map.delete(event, "retry")
    end
  end

  defp put_retry_metadata(event), do: event

  defp retry_metadata_event(%{"metadata" => %{"reconnection_delay_ms" => _delay_ms}} = event) do
    {:ok, event}
  end

  defp retry_metadata_event(_event), do: {:ok, nil}

  defp parse_retry_delay_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {delay_ms, ""} when delay_ms >= 0 -> {:ok, delay_ms}
      _ -> :ignore
    end
  end

  defp parse_retry_delay_ms(_value), do: :ignore

  defp strip_sse_value_prefix(" " <> value), do: value
  defp strip_sse_value_prefix(value), do: value
end
