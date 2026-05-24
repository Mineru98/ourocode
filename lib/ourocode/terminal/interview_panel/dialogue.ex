defmodule Ourocode.Terminal.InterviewPanel.Dialogue do
  @moduledoc false

  alias Ourocode.Terminal.InterviewPanel.Text

  @dialogue_tail 6

  @spec rows(map() | nil, boolean()) :: [{String.t(), atom()} | :rule]
  def rows(interview_state, drop_trailing_mcp?) do
    turns =
      interview_state
      |> dialogue()
      |> Enum.reverse()
      |> maybe_drop_trailing_mcp(drop_trailing_mcp?)

    turns
    |> Enum.take(-@dialogue_tail)
    |> Enum.reject(&internal_turn?/1)
    |> Enum.map(&row/1)
    |> Enum.intersperse(:rule)
  end

  defp dialogue(%{} = interview_state), do: Map.get(interview_state, :dialogue, [])
  defp dialogue(_interview_state), do: []

  defp maybe_drop_trailing_mcp(turns, true) do
    case List.last(turns) do
      %{role: :mcp} -> Enum.drop(turns, -1)
      _other -> turns
    end
  end

  defp maybe_drop_trailing_mcp(turns, _drop?), do: turns

  defp internal_turn?(%{role: :main, text: text}) when is_binary(text),
    do: leaked_router_prompt?(text)

  defp internal_turn?(_turn), do: false

  defp row(%{role: role, text: text}) do
    {label, style} =
      case role do
        :mcp -> {"MCP ", :warn}
        :main -> {"MAIN", :ok}
        :user -> {"YOU ", :strong}
        _other -> {"TURN", :dim}
      end

    {label <> "  " <> Text.flatten_line(text), style}
  end

  defp leaked_router_prompt?(text) when is_binary(text) do
    flat = String.replace(text, ~r/\s+/, " ")

    String.contains?(flat, [
      "You are the answerer/router half",
      "Routing rules (from the interview SKILL)",
      "Tool protocol",
      "Output exactly one directive as the first line",
      "ANSWER [from-code] <answer>",
      "ASK_USER <question for the human>"
    ]) or
      (String.length(flat) > 900 and
         String.contains?(flat, "ANSWER [from-code]") and
         String.contains?(flat, "ASK_USER"))
  end

  defp leaked_router_prompt?(_text), do: false
end
