defmodule Ourocode.Runtime.ActivitySnapshot do
  @moduledoc """
  Refresh helpers for the live Ouroboros activity and reasoning panes.
  """

  @spec refresh_activity(map(), [term()], map(), map(), pos_integer()) :: map()
  def refresh_activity(state, lines, offsets, activity_context, keep)
      when is_map(state) and is_list(lines) and is_map(offsets) and is_integer(keep) do
    activity =
      (Map.get(state, :ouroboros_activity, []) ++ lines)
      |> Enum.map(&enrich_activity_line(&1, activity_context))
      |> dedupe_activity()
      |> Enum.take(-keep)

    interview =
      case state.interview do
        %{} = iv when activity != [] -> Map.put(iv, :mcp_activity, activity)
        other -> other
      end

    %{state | ouroboros_log_offsets: offsets, ouroboros_activity: activity, interview: interview}
  end

  @spec refresh_session_reasoning(map(), [term()], map()) :: map()
  def refresh_session_reasoning(state, [], _reasoning_state), do: state

  def refresh_session_reasoning(state, lines, reasoning_state)
      when is_map(state) and is_list(lines) do
    interview =
      case state.interview do
        %{} = iv ->
          if Map.get(iv, :mcp_reasoning, []) == [] do
            iv
            |> Map.put(:mcp_reasoning, lines)
            |> maybe_put(:mcp_reasoning_state, reasoning_state)
          else
            iv
          end

        other ->
          other
      end

    %{state | interview: interview}
  end

  defp enrich_activity_line(line, %{initial_context: initial_context} = activity_context)
       when is_binary(line) and is_binary(initial_context) do
    cond do
      String.contains?(line, " · initial: ") ->
        line

      String.contains?(line, "interview started") ->
        line
        |> String.replace(~r/\s*·\s*\d+\s+chars/u, "")
        |> Kernel.<>(" · initial: #{initial_context}")

      true ->
        enrich_question_activity_line(line, activity_context)
    end
  end

  defp enrich_activity_line(line, activity_context) when is_binary(line) do
    enrich_question_activity_line(line, activity_context)
  end

  defp enrich_activity_line(line, _activity_context), do: line

  defp enrich_question_activity_line(line, %{questions: questions}) when is_map(questions) do
    cond do
      String.contains?(line, " · question: ") ->
        line

      true ->
        case Regex.run(~r/\bround\s+(\d+)\s+·\s+question generated\b/u, line) do
          [_match, round] ->
            case Integer.parse(round) do
              {round_number, ""} ->
                case Map.get(questions, round_number) do
                  question when is_binary(question) and question != "" ->
                    "round #{round_number} · question: #{question}"

                  _none ->
                    line
                end

              _error ->
                line
            end

          _no_match ->
            line
        end
    end
  end

  defp enrich_question_activity_line(line, _activity_context), do: line

  defp dedupe_activity(lines) do
    lines
    |> Enum.reverse()
    |> Enum.uniq_by(&activity_dedupe_key/1)
    |> Enum.reverse()
  end

  defp activity_dedupe_key(line) when is_binary(line) do
    line
    |> String.replace(~r/^activity:\s*/u, "")
    |> String.replace(~r/\s*·\s*\d+\s+chars/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp activity_dedupe_key(line), do: line

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
