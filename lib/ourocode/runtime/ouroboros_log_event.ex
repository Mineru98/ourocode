defmodule Ourocode.Runtime.OuroborosLogEvent do
  @moduledoc """
  Formats structured Ouroboros log events into compact activity text.
  """

  @spec format(String.t(), String.t(), map()) :: String.t()
  def format(level, event, fields)
      when is_binary(level) and is_binary(event) and is_map(fields) do
    level
    |> String.downcase()
    |> prefix(base_event(event, fields))
    |> normalize_spaces()
  end

  defp base_event("interview.started", fields) do
    compact_join([
      "interview started",
      session_part(fields, "interview_id"),
      chars_part(fields, "initial_context_length"),
      brownfield_part(fields)
    ])
  end

  defp base_event("interview.question_generated", fields) do
    compact_join([
      round_part(fields),
      "question generated",
      chars_part(fields, "question_length")
    ])
  end

  defp base_event("interview.response_recorded", fields) do
    compact_join([
      round_part(fields),
      "answer recorded",
      chars_part(fields, "response_length")
    ])
  end

  defp base_event("interview.state_saved", fields) do
    compact_join(["state saved", session_part(fields, "interview_id")])
  end

  defp base_event("mcp.tool.interview.started", fields) do
    compact_join(["mcp interview started", session_part(fields, "session_id")])
  end

  defp base_event("mcp.tool.interview.question_asked", fields) do
    compact_join(["mcp question asked", session_part(fields, "session_id")])
  end

  defp base_event("mcp.tool.interview.response_recorded", fields) do
    compact_join(["mcp answer recorded", session_part(fields, "session_id")])
  end

  defp base_event("mcp.tool.interview.error", fields) do
    compact_join(["mcp interview error", Map.get(fields, "error")])
  end

  defp base_event(event, fields), do: fallback_event(event, fields)

  defp prefix("warning", base), do: "warning: " <> base
  defp prefix("error", base), do: "error: " <> base
  defp prefix(_level, base), do: base

  defp compact_join(parts) do
    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp session_part(fields, key) do
    case Map.get(fields, key) do
      nil -> nil
      "" -> nil
      id -> "session " <> short_id(id)
    end
  end

  defp round_part(fields) do
    case Map.get(fields, "round_number") do
      nil -> nil
      "" -> nil
      round -> "round " <> round
    end
  end

  defp chars_part(fields, key) do
    case Map.get(fields, key) do
      nil -> nil
      "" -> nil
      chars -> chars <> " chars"
    end
  end

  defp brownfield_part(fields) do
    case Map.get(fields, "is_brownfield") do
      value when value in ["True", "true"] -> "brownfield"
      value when value in ["False", "false"] -> "new project"
      _other -> nil
    end
  end

  defp fallback_event(event, fields) do
    details =
      fields
      |> Enum.reject(fn {key, _value} -> key in ["filename", "lineno", "file_path"] end)
      |> Enum.take(3)
      |> Enum.map_join(" · ", fn {key, value} -> "#{key} #{value}" end)

    compact_join([event, details])
  end

  defp short_id(id) when is_binary(id) do
    id
    |> String.replace_prefix("interview_", "")
    |> case do
      <<prefix::binary-size(15), _rest::binary>> = full when byte_size(full) > 15 ->
        prefix <> "..."

      short ->
        short
    end
  end

  defp normalize_spaces(text), do: String.replace(text, ~r/\s+/, " ") |> String.trim()
end
