defmodule Ourocode.Runtime.InterviewOptionGenerator do
  @moduledoc """
  Uses the active main-session model to generate suggested interview answers.

  The deterministic `InterviewOptionSynthesizer` remains a final fallback. This
  module is the preferred path when the router or MCP server did not provide
  `question_options`: ask the main session to produce a small answer sheet for
  the user instead of guessing from string parsing.
  """

  alias Ourocode.Model

  alias Ourocode.Runtime.{
    InterviewResponse,
    InterviewRouter.Directive
  }

  @option_re ~r/\A[-*]\s*(.+?)\s*[|｜]\s*(.+)\z/u
  @default_timeout_ms 1_500

  @type option :: %{label: String.t(), description: String.t()}

  @spec generate(String.t(), Model.t(), keyword()) :: {:ok, [option()]} | {:error, term()}
  def generate(question, model, opts \\ [])

  def generate(question, %Model{} = model, opts) when is_binary(question) and is_list(opts) do
    timeout_ms = timeout_ms(opts)

    cond do
      not Model.ready?(model) ->
        {:error, :model_unavailable}

      timeout_ms <= 0 ->
        {:error, :invalid_timeout}

      true ->
        on_reason =
          Keyword.get(opts, :on_reason) || Keyword.get(opts, :on_chunk, fn _chunk -> :ok end)

        run_with_timeout(model, question, timeout_ms, on_reason)
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

    trap_exit? = Process.flag(:trap_exit, true)

    try do
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, options}} -> {:ok, options}
        {:ok, {:error, reason}} -> {:error, reason}
        {:exit, reason} -> {:error, {:generator_exited, reason}}
        nil -> {:error, :generator_timeout}
      end
    after
      Process.flag(:trap_exit, trap_exit?)
    end
  end

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, @default_timeout_ms) do
      value when is_integer(value) -> value
      _other -> @default_timeout_ms
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
      |> directive_or_lines()
      |> Enum.reject(&blank_option?/1)
      |> Enum.map(&clean_option/1)
      |> Enum.reject(&blank_option?/1)
      |> Enum.uniq_by(& &1.label)
      |> Enum.take(4)

    if length(options) >= 2, do: {:ok, options}, else: {:error, :no_options}
  end

  def parse(_text), do: {:error, :no_options}

  defp directive_or_lines(text) do
    case Directive.parse(text) do
      {:ask_user, _prompt, options} when is_list(options) -> options
      _other -> parse_option_lines(text)
    end
  end

  defp parse_option_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(&parse_line/1)
  end

  defp parse_line(line) do
    case Regex.run(@option_re, line) do
      [_match, label, description] ->
        [%{label: label, description: description}]

      _no_match ->
        []
    end
  end

  defp clean_option(%{label: label, description: description}) do
    %{label: clean_field(label), description: clean_field(description)}
  end

  defp blank_option?(%{label: label, description: description}) do
    not usable?(label) or not usable?(description)
  end

  defp blank_option?(_option), do: true

  defp clean_field(text) do
    text
    |> InterviewResponse.clean_markdown()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp usable?(text), do: is_binary(text) and String.length(String.trim(text)) >= 2
end
