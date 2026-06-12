defmodule Ourocode.Runtime.InterviewRouter.Prompt do
  @moduledoc false

  @max_turns 6

  # The router loop re-sends every accumulated observation on each turn, so
  # an old tool output is paid for again on every remaining turn. Beyond this
  # budget the newest observations stay verbatim and older oversized ones
  # collapse to a pruned marker; the model can re-run the tool when it still
  # needs the content. Observations at or under the floor are always kept —
  # pruning them saves almost nothing but loses routing evidence.
  @observations_budget_bytes 24_576
  @prune_floor_bytes 512

  @doc false
  @spec max_turns() :: pos_integer()
  def max_turns, do: @max_turns

  @doc false
  @spec build(String.t(), [{String.t(), String.t()}], pos_integer()) :: String.t()
  def build(question, observations, turn) when is_binary(question) and is_list(observations) do
    """
    #{system_rules()}

    ## MCP question (turn #{turn}/#{@max_turns})
    #{question}

    #{observations_block(observations)}
    ## Your reply
    Output exactly one directive as the first line. No prose before it.
    """
  end

  defp observations_block([]), do: ""

  defp observations_block(observations) do
    body =
      observations
      |> prune_to_budget()
      |> Enum.map(fn {label, out} -> "### #{label}\n#{out}" end)
      |> Enum.join("\n\n")

    "## Tool observations so far\n#{body}\n"
  end

  # Newest-first walk under the byte budget; the newest observation always
  # survives in full (it is what the model just asked for).
  defp prune_to_budget(observations) do
    {kept, _used} =
      observations
      |> Enum.reverse()
      |> Enum.map_reduce(0, fn {label, out}, used ->
        size = byte_size(out)

        if used == 0 or size <= @prune_floor_bytes or
             used + size <= @observations_budget_bytes do
          {{label, out}, used + size}
        else
          {{label,
            "[pruned #{size}-byte output to keep this prompt small; " <>
              "re-run the tool if you still need it]"}, used}
        end
      end)

    Enum.reverse(kept)
  end

  defp system_rules do
    """
    You are the answerer/router half of an Ouroboros Socratic interview. The MCP
    server generates questions but CANNOT read code. You answer factual questions
    from the codebase and route human-judgment questions to the user.

    Routing rules (from the interview SKILL):
    - Factual question about the EXISTING stack, frameworks, dependencies, current
      patterns, architecture, or file structure → find the fact in code, then
      ANSWER prefixed `[from-code]`. Describe what exists; never prescribe what a
      new feature should do.
    - Fact only knowable from external/industry knowledge (APIs, pricing, library
      capabilities) → ANSWER prefixed `[from-research]` (state the fact plainly).
    - Goals, vision, acceptance criteria, business logic, preferences, tradeoffs,
      scope, or desired behaviour for NEW features → ASK_USER. Any question that
      mixes facts with a decision goes ASK_USER in full.
    - When in doubt, ASK_USER. It is safer to ask the user than to guess.

    Tool protocol — emit ONE directive as the first line, nothing before it:
      TOOL READ <relative/path>            read a file (read-only, project-bounded)
      TOOL GLOB <relative/glob>            list files matching a wildcard
      TOOL GREP <pattern> [include-glob]   recursive grep within the project
      ANSWER [from-code] <answer>          commit a code-derived factual answer
      ANSWER [from-research] <answer>      commit an external-knowledge fact
      ASK_USER <question for the human>    route a human-judgment question

    For ASK_USER, first digest the MCP question into a clean user-facing
    question. If the MCP text already contains examples, numbered choices, or
    candidate axes, reinterpret them semantically as suggested options instead
    of echoing the raw list inside the question.

    After the ASK_USER question line, add 2-4 suggested-answer options so
    the user can pick or free-type (SKILL PATH 2 "with suggested options"),
    one per line, exactly:
      - <short label> | <one-line description of what choosing it means>
    Make the options concrete, mutually distinct decisions a human would
    actually choose between (not "yes/no" unless the question is binary).
    Use plain text only for labels and descriptions: no emoji, icons, decorative
    symbols, markdown, or extra `|` characters except the single delimiter.

    Use TOOL turns to gather evidence before ANSWER. Keep the ANSWER faithful to
    the user's request: state facts, preserve constraints, do not compress away
    reasoning. Absolute paths, `..`, and `~` are rejected by the sandbox.
    """
  end
end
