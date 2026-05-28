defmodule Ourocode.Terminal.InterviewPanel.Status do
  @moduledoc false

  alias Ourocode.Terminal.{InterviewPanel.Text, PromptActivityIndicator}

  @spec working_line(integer(), term()) :: String.t()
  def working_line(tick, trace), do: working_line(tick, trace, nil)

  @spec working_line(integer(), term(), non_neg_integer() | nil) :: String.t()
  def working_line(tick, trace, elapsed_seconds) do
    step =
      if is_binary(trace) and trace != "",
        do: router_trace_label(trace),
        else: waiting_label(elapsed_seconds)

    spin(tick) <> " " <> step
  end

  @spec reasoning_lines(map(), integer() | nil, boolean()) :: [String.t()]
  def reasoning_lines(iv, tick, paused?) when is_map(iv) do
    [
      status_line(iv, tick, paused?),
      mcp_reasoning_lines(iv),
      fallback_reasoning_lines(iv),
      complete_line(iv)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  def reasoning_lines(_iv, _tick, _paused?), do: []

  @spec mcp_activity_lines([term()]) :: [String.t()]
  def mcp_activity_lines(lines) when is_list(lines) do
    lines
    |> Enum.take(-80)
    |> Enum.map(&activity_display_line/1)
    |> Enum.reject(&(&1 == "activity: "))
  end

  def mcp_activity_lines(_lines), do: []

  @spec spin(integer() | term()) :: String.t()
  def spin(tick) when is_integer(tick) do
    PromptActivityIndicator.frame(max(tick, 0))
  end

  def spin(_tick), do: PromptActivityIndicator.frame(0)

  defp router_trace_label(trace) do
    clean = Text.flatten_line(trace)
    upcased = String.upcase(clean)

    cond do
      String.starts_with?(upcased, "ASK_USER") ->
        "question ready - choose or type an answer in the interview block"

      answer = Regex.run(~r/^ANSWER(?:\s+\[[^\]]+\])?:\s*(.+)$/i, clean) ->
        "main session answered: " <> Enum.at(answer, 1)

      String.starts_with?(upcased, "ANSWER") ->
        "main session answered from context"

      String.starts_with?(upcased, "TOOL") ->
        "main session is checking project context"

      String.starts_with?(upcased, "PATH") ->
        "main session is choosing the next interview step"

      true ->
        clean
    end
  end

  defp status_line(_iv, _tick, true), do: "step paused - discussing with main session"

  defp status_line(%{waiting: true, status: s}, tick, false) when is_binary(s) and s != "" do
    label =
      case String.downcase(s) do
        "waiting for mcp interview question" ->
          "step received - preparing the interview question"

        "waiting for mcp follow-up question" ->
          "step routing - preparing the next question"

        "preparing next interview question" ->
          "step routing - preparing the next question"

        "opening interview session to send answer" ->
          "step syncing - opening interview session"

        "answer sent - generating next question" ->
          "step routing - answer sent, generating choices"

        "waiting for your answer" ->
          "step waiting - waiting for your answer"

        _other ->
          s
      end

    if waiting_for_user_status?(s) do
      label
    else
      if is_integer(tick), do: spin(tick) <> " " <> label, else: label
    end
  end

  defp status_line(%{status: s}, _tick, _paused) when is_binary(s) and s != "",
    do: "step active - " <> s

  defp status_line(_iv, _tick, _paused), do: nil

  defp waiting_label(elapsed_seconds) when is_integer(elapsed_seconds) and elapsed_seconds >= 15,
    do: "still building choices (~#{elapsed_seconds}s) - working, not stuck; Esc adds context"

  defp waiting_label(elapsed_seconds) when is_integer(elapsed_seconds) and elapsed_seconds >= 6,
    do: "building answer choices (~#{elapsed_seconds}s) - no input needed; Esc pauses"

  defp waiting_label(_elapsed_seconds),
    do: "building the first question - choices will appear here"

  defp mcp_reasoning_lines(%{mcp_reasoning: lines}) when is_list(lines) do
    lines
    |> Enum.map(&Text.flatten_line/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp mcp_reasoning_lines(_iv), do: []

  defp fallback_reasoning_lines(%{mcp_reasoning: lines}) when is_list(lines) and lines != [],
    do: []

  defp fallback_reasoning_lines(iv) do
    [
      session_line(iv),
      ambiguity_line(iv),
      milestone_line(iv),
      seed_ready_line(iv)
    ] ++ breakdown_lines(iv)
  end

  defp session_line(%{session_id: s}) when is_binary(s) and s != "",
    do: "session " <> s

  defp session_line(_iv), do: nil

  defp ambiguity_line(%{ambiguity: a}) when is_float(a) or is_integer(a),
    do: "ambiguity #{:erlang.float_to_binary(a / 1, decimals: 2)}"

  defp ambiguity_line(_iv), do: nil

  defp milestone_line(%{milestone: m}) when is_binary(m) and m != "", do: "milestone " <> m
  defp milestone_line(_iv), do: nil

  defp seed_ready_line(%{seed_ready: true}), do: "seed-ready: yes"
  defp seed_ready_line(%{seed_ready: false}), do: "seed-ready: no"
  defp seed_ready_line(_iv), do: nil

  defp breakdown_lines(%{breakdown: b}) when is_map(b) do
    Enum.map(b, fn {k, v} -> "#{k}: #{inspect(v)}" end)
  end

  defp breakdown_lines(_iv), do: []

  defp complete_line(%{complete: reason}) when not is_nil(reason),
    do: "interview complete: #{reason}"

  defp complete_line(_iv), do: nil

  defp waiting_for_user_status?(status) when is_binary(status),
    do: String.downcase(status) == "waiting for your answer"

  defp waiting_for_user_status?(_status), do: false

  defp activity_display_line(line) do
    line = Text.plain_line(line)

    if String.starts_with?(line, "activity: "),
      do: line,
      else: "activity: " <> line
  end
end
