defmodule Ourocode.Dashboard.WonderToolPromptRenderer do
  @moduledoc """
  Data-only renderer for wonderTool multiple-choice prompts.

  wonderTool prompts are inspired by AskUserQuestion-style checkpoints for
  decisions, permissions, and clarifications. This renderer accepts either
  already normalized `Ourocode.WonderTool.DecisionRequest` data or a raw runtime
  payload that can be parsed by that module, then returns a consistent
  option-list projection for terminal panes.
  """

  alias Ourocode.WonderTool.DecisionRequest

  @type rendered_option :: %{
          required(:index) => pos_integer(),
          required(:marker) => String.t(),
          required(:label) => String.t(),
          required(:description) => String.t(),
          required(:recommended?) => boolean(),
          optional(:other?) => boolean(),
          optional(:preview) => String.t(),
          optional(:preview_placeholders) => [String.t()],
          required(:line) => String.t()
        }

  @type rendered_question :: %{
          required(:id) => String.t(),
          required(:kind) => String.t(),
          required(:header) => String.t(),
          required(:question) => String.t(),
          required(:options) => [rendered_option()],
          required(:lines) => [String.t()]
        }

  @type rendered_prompt :: %{
          required(:id) => :wonder_tool,
          required(:kind) => :wonder_tool_multiple_choice_prompt,
          required(:title) => String.t(),
          required(:request_id) => String.t() | nil,
          required(:child_id) => String.t() | nil,
          required(:parent_call_id) => String.t() | nil,
          required(:question_count) => non_neg_integer(),
          required(:questions) => [rendered_question()],
          required(:lines) => [String.t()]
        }

  @doc """
  Renders a wonderTool multiple-choice prompt into a stable pane projection.
  """
  @spec render(map()) :: rendered_prompt()
  def render(
        %{tool: :wonder_tool, type: :multiple_choice_decision, questions: questions} = request
      )
      when is_list(questions) do
    questions = Enum.map(questions, &render_question/1)

    %{
      id: :wonder_tool,
      kind: :wonder_tool_multiple_choice_prompt,
      title: "wonderTool",
      request_id: Map.get(request, :request_id),
      child_id: Map.get(request, :child_id),
      parent_call_id: Map.get(request, :parent_call_id),
      question_count: length(questions),
      questions: questions,
      lines: prompt_lines(questions)
    }
  end

  def render(request) when is_map(request) do
    case DecisionRequest.parse(request) do
      {:ok, normalized} -> render(normalized)
      {:error, reason} -> raise ArgumentError, "invalid wonderTool prompt: #{inspect(reason)}"
    end
  end

  @doc """
  Formats a rendered prompt as terminal-ready lines.
  """
  @spec render_lines(map()) :: [String.t()]
  def render_lines(%{lines: lines}) when is_list(lines), do: lines
  def render_lines(request) when is_map(request), do: request |> render() |> Map.fetch!(:lines)

  @doc """
  Formats a rendered prompt as a compact terminal string.
  """
  @spec render_line(map()) :: String.t()
  def render_line(request) when is_map(request) do
    request
    |> render_lines()
    |> Enum.join("\n")
  end

  defp render_question(question) do
    kind = question |> Map.get(:kind, :decision) |> stringify()
    options = question.options |> Enum.with_index(1) |> Enum.map(&render_option/1)

    lines = [
      "[#{kind}] #{question.header}: #{question.question}"
      | Enum.map(options, & &1.line)
    ]

    %{
      id: question.id,
      kind: kind,
      header: question.header,
      question: question.question,
      options: options,
      lines: lines
    }
  end

  defp render_option({option, index}) do
    recommended? = Map.get(option, :recommended?, false)
    marker = "#{index}."
    preview = preview_text(option)
    line = "  #{marker} #{option.label} - #{option.description}" <> preview_suffix(preview)

    %{
      index: index,
      marker: marker,
      label: option.label,
      description: option.description,
      recommended?: recommended?,
      other?: Map.get(option, :other?, false),
      preview: Map.get(option, :preview),
      preview_placeholders: preview,
      line: line
    }
  end

  defp preview_text(option) do
    []
    |> maybe_append(Map.get(option, :preview))
    |> maybe_append(Map.get(option, :preview_placeholder))
    |> Kernel.++(Map.get(option, :preview_placeholders, []))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp preview_suffix([]), do: ""
  defp preview_suffix(previews), do: " [preview: " <> Enum.join(previews, ", ") <> "]"

  defp maybe_append(list, value) when is_binary(value), do: list ++ [value]
  defp maybe_append(list, _value), do: list

  defp prompt_lines(questions) do
    questions
    |> Enum.flat_map(& &1.lines)
  end

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
end
