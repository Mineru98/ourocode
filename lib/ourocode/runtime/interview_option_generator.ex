defmodule Ourocode.Runtime.InterviewOptionGenerator do
  @moduledoc """
  Generates LLM-suggested choices for interview questions before static fallback.
  """

  alias Ourocode.Model
  alias Ourocode.Runtime.InterviewRouter.Directive

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
        run_bounded(fn -> generate_live(question, model, opts) end, timeout_ms)
    end
  end

  def generate(_question, _model, _opts), do: {:error, :invalid_args}

  defp generate_live(question, model, opts) do
    prompt = prompt(question)
    on_chunk = Keyword.get(opts, :on_chunk, fn _chunk -> :ok end)

    with {:ok, text} <- Model.stream(model, prompt, [], on_chunk),
         [_first | _rest] = options <- parse_options(text) do
      {:ok, options}
    else
      [] -> {:error, :no_options}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_bounded(fun, timeout_ms) do
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      task = Task.async(fun)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, options}} -> {:ok, options}
        {:ok, {:error, reason}} -> {:error, reason}
        {:exit, reason} -> {:error, {:generator_exited, reason}}
        nil -> {:error, :timeout}
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
    """
    Generate suggested-answer options for this interview question.

    Question:
    #{question}

    Output 2-4 concrete choices the user could actually select. The user can
    still free-type separately, so do not include "Custom answer".

    Format each line exactly:
    - <short label> | <one-line description>

    No prose before or after the option lines.
    """
  end

  defp parse_options(text) when is_binary(text) do
    text
    |> Directive.parse()
    |> case do
      {:ask_user, _prompt, options} -> options
      _other -> parse_option_lines(text)
    end
    |> Enum.take(4)
    |> Enum.reject(&blank_option?/1)
  end

  defp parse_options(_text), do: []

  defp parse_option_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&parse_option_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_option_line(line) do
    case Regex.run(~r/\A\s*[-*]\s*(.+?)\s*[|｜]\s*(.+?)\s*\z/u, line) do
      [_, label, description] ->
        %{label: String.trim(label), description: String.trim(description)}

      _no_match ->
        nil
    end
  end

  defp blank_option?(%{label: label, description: description}) do
    String.trim(label) == "" or String.trim(description) == ""
  end
end
