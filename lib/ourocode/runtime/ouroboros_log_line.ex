defmodule Ourocode.Runtime.OuroborosLogLine do
  @moduledoc """
  Pure formatting of Ouroboros log lines into compact activity rows.
  """

  alias Ourocode.Runtime.{OuroborosLogEvent, OuroborosLogFields}

  @interesting_prefixes [
    "auto",
    "interview",
    "mcp.tool.interview",
    "mcp.tool.generate_seed",
    "mcp.tool.execute_seed",
    "seed",
    "execution",
    "evolve",
    "ralph"
  ]

  @spec parse(term()) :: [String.t()]
  def parse(line) when is_binary(line) do
    line = line |> strip_ansi() |> String.trim()

    cond do
      line == "" ->
        []

      String.starts_with?(line, "[auto]") ->
        [line |> String.replace_prefix("[auto]", "auto:") |> normalize_spaces()]

      true ->
        parse_structured_line(line)
    end
  end

  def parse(_line), do: []

  defp parse_structured_line(line) do
    case Regex.run(~r/^\S+\s+\[\s*([a-zA-Z]+)\s*\]\s+([^\s]+)\s*(.*)$/, line) do
      [_all, level, event, kv] ->
        if interesting_event?(event),
          do: [OuroborosLogEvent.format(level, event, OuroborosLogFields.parse(kv))],
          else: []

      _no_match ->
        []
    end
  end

  defp interesting_event?(event) do
    Enum.any?(@interesting_prefixes, fn prefix ->
      event == prefix or String.starts_with?(event, prefix <> ".")
    end)
  end

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")
  defp normalize_spaces(text), do: String.replace(text, ~r/\s+/, " ") |> String.trim()
end
