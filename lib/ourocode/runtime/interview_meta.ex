defmodule Ourocode.Runtime.InterviewMeta do
  @moduledoc """
  Metadata extraction and lookup helpers for interview MCP responses/events.
  """

  @spec response_meta(map(), String.t()) :: map()
  def response_meta(response, text) when is_map(response) do
    result = if is_map(response["result"]), do: response["result"], else: %{}
    structured = structured_content(result)

    [
      result["meta"],
      result["_meta"],
      structured["meta"],
      structured["_meta"],
      structured,
      content_meta(result),
      decode_text_meta(text)
    ]
    |> merge_candidates()
  end

  def response_meta(_response, _text), do: %{}

  @spec event_meta(map()) :: map()
  def event_meta(event) when is_map(event) do
    payload = if is_map(event[:payload]), do: event[:payload], else: %{}
    result = if is_map(payload["result"]), do: payload["result"], else: %{}
    structured = structured_content(result)

    [
      event[:meta],
      event["meta"],
      event[:_meta],
      event["_meta"],
      payload[:meta],
      payload["meta"],
      payload[:_meta],
      payload["_meta"],
      result["meta"],
      result["_meta"],
      structured["meta"],
      structured["_meta"],
      structured,
      content_meta(result)
    ]
    |> merge_candidates()
  end

  def event_meta(_event), do: %{}

  @spec value(map(), String.t()) :: term()
  def value(meta, key) when is_map(meta) do
    case Map.fetch(meta, key) do
      {:ok, value} -> value
      :error -> Map.get(meta, safe_atom(key))
    end
  end

  def value(_meta, _key), do: nil

  @spec numeric_value(map(), String.t()) :: float() | nil
  def numeric_value(meta, key) do
    case value(meta, key) do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      value when is_binary(value) -> parse_float(value)
      _other -> nil
    end
  end

  defp structured_content(%{"structuredContent" => value}) when is_map(value), do: value
  defp structured_content(%{"structured_content" => value}) when is_map(value), do: value
  defp structured_content(_result), do: %{}

  defp content_meta(%{"content" => content}) when is_list(content) do
    content
    |> Enum.find_value(%{}, fn
      %{"meta" => meta} when is_map(meta) -> meta
      %{"_meta" => meta} when is_map(meta) -> meta
      %{"annotations" => %{"meta" => meta}} when is_map(meta) -> meta
      %{meta: meta} when is_map(meta) -> meta
      %{_meta: meta} when is_map(meta) -> meta
      _part -> nil
    end)
  end

  defp content_meta(_result), do: %{}

  defp merge_candidates(candidates) do
    candidates
    |> Enum.filter(&is_map/1)
    |> Enum.reject(&(&1 == %{}))
    |> Enum.reduce(%{}, fn candidate, acc -> Map.merge(acc, candidate) end)
  end

  defp decode_text_meta(text) when is_binary(text) do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "{") do
      case Ourocode.Json.decode(trimmed) do
        {:ok, %{} = body} -> body
        _error -> %{}
      end
    else
      %{}
    end
  end

  defp decode_text_meta(_text), do: %{}

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {f, _rest} -> f
      :error -> nil
    end
  end
end
