defmodule Ourocode.Runtime.InterviewOptionGenerator do
  @moduledoc """
  Uses the active main-session model to generate suggested interview answers.

  The deterministic `InterviewOptionSynthesizer` remains a final fallback. This
  module is the preferred path when the router or MCP server did not provide
  `question_options`: ask the main session to produce a small answer sheet for
  the user instead of guessing from string parsing.
  """

  alias Ourocode.Model
  alias Ourocode.Runtime.InterviewResponse

  @option_re ~r/\A[-*]\s*(.+?)\s*[|｜]\s*(.+)\z/u
  @default_timeout_ms 1_500

  @type option :: %{label: String.t(), description: String.t()}

  @spec generate(String.t(), Model.t(), keyword()) :: {:ok, [option()]} | {:error, term()}
  def generate(question, model, opts \\ [])

  def generate(question, %Model{} = model, opts) when is_binary(question) and is_list(opts) do
    if Model.ready?(model) do
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      on_reason = Keyword.get(opts, :on_reason, fn _chunk -> :ok end)

      run_with_timeout(model, question, timeout_ms, on_reason)
    else
      {:error, :model_unavailable}
    end
  end

  def generate(_question, _model, _opts), do: {:error, :invalid_generator_args}

  defp run_with_timeout(model, question, timeout_ms, on_reason) do
    task =
      Task.async(fn ->
        case Model.stream(model, prompt(question), [], on_reason) do
          {:ok, text} -> parse(text)
          {:error, reason} -> {:error, {:model_failed, reason}}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, options}} -> {:ok, options}
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:error, {:generator_exited, reason}}
      nil -> {:error, :generator_timeout}
    end
  end

  defp prompt(question) do
    question = InterviewResponse.clean_markdown(question)

    """
    You are the main session helping an Ouroboros interview UI.

    Create 2-4 suggested answers for the user to choose from for this interview
    question. Do not answer the question yourself. Offer plausible user choices.

    Rules:
    - Output only option lines.
    - Each line must be exactly: - <short label> | <one-line description>
    - Labels must be concrete choices, not generic placeholders.
    - Match the user's language.
    - Do not include prose, numbering, markdown headings, or JSON.

    Interview question:
    #{question}
    """
  end

  @doc false
  @spec parse(String.t()) :: {:ok, [option()]} | {:error, :no_options}
  def parse(text) when is_binary(text) do
    options =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.flat_map(&parse_line/1)
      |> Enum.uniq_by(& &1.label)
      |> Enum.take(4)

    if length(options) >= 2, do: {:ok, options}, else: {:error, :no_options}
  end

  def parse(_text), do: {:error, :no_options}

  defp parse_line(line) do
    case Regex.run(@option_re, line) do
      [_match, label, description] ->
        label = clean_field(label)
        description = clean_field(description)

        if usable?(label) and usable?(description) do
          [%{label: label, description: description}]
        else
          []
        end

      _no_match ->
        []
    end
  end

  defp clean_field(text) do
    text
    |> InterviewResponse.clean_markdown()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp usable?(text), do: is_binary(text) and String.length(text) >= 2
end
