defmodule Ourocode.Runtime.InterviewRouter do
  @moduledoc """
  SKILL Path A router: turns one MCP interview question into either a
  code/research-derived answer or a routed-to-user prompt.

  The Ouroboros MCP is a pure question generator — it cannot read code. This
  module is the "answerer + router" half of the SKILL contract:

      MCP (question generator) ←→ Router (answerer + router) ←→ User (judgment)

  `Ourocode.Model` is a plain text-stream runner (no native tool calls), so the
  agent loop is a **text protocol**: the model emits one constrained directive
  per turn and `decide/4` executes read-only tools on its behalf, feeding the
  observation back until the model commits to `ANSWER` or `ASK_USER`.

  Hard rules taken straight from `skills/interview/SKILL.md`:

    * Facts (current stack/architecture/files) are answerable from code →
      `ANSWER [from-code] …`. Research facts → `ANSWER [from-research] …`.
      Decisions / goals / acceptance criteria / tradeoffs are human judgment →
      `ASK_USER …`. When in doubt, `ASK_USER`.
    * Dialectic Rhythm Guard: after 3 consecutive non-user answers the next
      question is forced to the user even if it looks code-answerable.
    * If the answerer model is not `ready?`, every question is routed to the
      user (the SKILL Path B / #2a fallback, automatic).

  The tool sandbox is read-only and project-bounded: relative paths only, no
  `..` escape, no absolute paths, bounded read/grep output, capped turns.
  """

  alias Ourocode.Model
  alias Ourocode.Runtime.InterviewRouter.Directive
  alias Ourocode.Runtime.InterviewRouter.Prompt
  alias Ourocode.Runtime.InterviewRouter.ToolSandbox

  @max_turns Prompt.max_turns()

  @type source :: :code | :research | :user
  @type option :: %{label: String.t(), description: String.t()}
  @type decision ::
          {:answer, String.t(), source()}
          | {:ask_user, String.t(), [option()]}
          | {:error, term()}

  @doc """
  Decides how to handle one MCP interview question.

  `ctx` carries at least `:project_dir` (read-only sandbox root) and `:streak`
  (consecutive non-user answers, for the Dialectic Rhythm Guard). `model` is an
  `Ourocode.Model.t()`; when it is not `ready?` every question is routed to the
  user. Sinks (optional `(binary -> any)`):

    * `opts[:on_trace]` — one compact line per router PATH decision / tool
      activity.
    * `opts[:on_reason]` — the answerer model's streamed reasoning chunks as
      they arrive (the main session's live thinking). Surfaced in the LEFT
      transcript block; never discarded.

  `ASK_USER` carries up to 4 model-suggested options so it can be presented
  as a wonderTool checkpoint (SKILL PATH 2 "with suggested options").
  """
  @spec decide(String.t(), map(), Model.t(), keyword()) :: decision()
  def decide(question, ctx, model, opts \\ [])

  def decide(question, ctx, %Model{} = model, opts)
      when is_binary(question) and is_map(ctx) and is_list(opts) do
    io = %{trace: sink(opts, :on_trace), reason: sink(opts, :on_reason)}
    question = clean_question(question)

    cond do
      not Model.ready?(model) ->
        io.trace.("PATH 2 (model unavailable → user): #{truncate(question, 80)}")
        {:ask_user, question, []}

      dialectic_guard_tripped?(ctx) ->
        io.trace.("PATH 2 (Dialectic Rhythm Guard, 3 non-user answers): forced to user")
        {:ask_user, question, []}

      true ->
        project_dir = sandbox_root(ctx)
        loop(model, question, project_dir, [], 1, io)
    end
  rescue
    exception -> {:error, {:router_exception, Exception.message(exception)}}
  end

  def decide(_question, _ctx, _model, _opts), do: {:error, :invalid_router_args}

  defp clean_question(question) do
    question
    |> String.replace(~r/(\*\*|__)(.*?)\1/s, "\\2")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.trim()
  end

  # --- agent loop ----------------------------------------------------------

  defp loop(_model, question, _root, _obs, turn, io) when turn > @max_turns do
    io.trace.("PATH 2 (turn cap #{@max_turns} reached → user): when in doubt, ask")
    {:ask_user, question, []}
  end

  defp loop(model, question, root, observations, turn, io) do
    prompt = Prompt.build(question, observations, turn)
    on_chunk = fn chunk -> if is_binary(chunk) and chunk != "", do: io.reason.(chunk) end

    case Model.stream(model, prompt, [], on_chunk) do
      {:ok, text} ->
        text
        |> parse_directive()
        |> dispatch(model, question, root, observations, turn, io)

      {:error, reason} ->
        {:error, {:model_failed, reason}}
    end
  end

  defp dispatch({:answer, payload}, _model, _q, _root, _obs, _turn, io) do
    source = source_of(payload)
    io.trace.("ANSWER [#{source}]: #{truncate(payload, 80)}")
    {:answer, payload, source}
  end

  defp dispatch({:ask_user, prompt, options}, _model, _q, _root, _obs, _turn, io) do
    io.trace.("ASK_USER (#{length(options)} opt): #{truncate(prompt, 80)}")
    {:ask_user, prompt, options}
  end

  defp dispatch({:tool, tool, arg}, model, question, root, observations, turn, io) do
    {label, observation} = ToolSandbox.run(tool, arg, root)
    io.trace.("TOOL #{label} (turn #{turn})")
    loop(model, question, root, observations ++ [{label, observation}], turn + 1, io)
  end

  defp dispatch(:unparseable, model, question, root, observations, turn, io) do
    # A malformed turn is not fatal: nudge once with an explicit reminder, then
    # fall back to ASK_USER via the turn cap. Never invent a routing decision.
    io.trace.("router: unparseable model output (turn #{turn}) — reprompting")

    loop(
      model,
      question,
      root,
      observations ++ [{"FORMAT", "Previous reply was not a valid directive."}],
      turn + 1,
      io
    )
  end

  # --- directive parser ----------------------------------------------------

  @doc false
  @spec parse_directive(String.t()) ::
          {:answer, String.t()}
          | {:ask_user, String.t(), [option()]}
          | {:tool, atom(), String.t()}
          | :unparseable
  def parse_directive(text), do: Directive.parse(text)

  defp source_of(payload) do
    cond do
      String.contains?(payload, "[from-research]") -> :research
      String.contains?(payload, "[from-user]") -> :user
      true -> :code
    end
  end

  defp sandbox_root(ctx) do
    (ctx[:project_dir] || ctx[:cwd] || File.cwd!())
    |> Path.expand()
  end

  # --- guards / helpers ----------------------------------------------------

  defp dialectic_guard_tripped?(ctx) do
    case Map.get(ctx, :streak, 0) do
      n when is_integer(n) -> n >= 3
      _other -> false
    end
  end

  defp sink(opts, key) do
    case Keyword.get(opts, key) do
      fun when is_function(fun, 1) -> fun
      _none -> fn _line -> :ok end
    end
  end

  defp truncate(text, max) when is_binary(text) do
    flat = text |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(flat) <= max, do: flat, else: String.slice(flat, 0, max) <> "…"
  end
end
