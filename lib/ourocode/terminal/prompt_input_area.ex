defmodule Ourocode.Terminal.PromptInputArea do
  @moduledoc """
  Terminal-native input prompt area projection.

  The dashboard prompt remains the state source, while this module owns the
  terminal rendering boundary for the persistent natural-language input loop.
  Slash commands and free-form task prompts share this area in later layers.
  """

  alias Ourocode.Dashboard.TaskPromptInput

  @type rendered_area :: %{
          required(:kind) => :terminal_prompt_input_area,
          required(:id) => :task_prompt,
          required(:title) => String.t(),
          required(:line) => String.t(),
          required(:input_mode) => :natural_language_or_slash_command,
          required(:focused?) => boolean(),
          required(:editable?) => boolean(),
          optional(:layout) => map()
        }

  @doc """
  Builds a render-ready terminal prompt area from the dashboard prompt state.
  """
  @spec render(TaskPromptInput.t() | map()) :: rendered_area()
  def render(%{id: :task_prompt, title: title} = prompt) when is_binary(title) do
    %{
      kind: :terminal_prompt_input_area,
      id: :task_prompt,
      title: title,
      line: TaskPromptInput.render_line(prompt),
      input_mode: :natural_language_or_slash_command,
      focused?: Map.get(prompt, :focused?, false),
      editable?: Map.get(prompt, :editable?, false)
    }
    |> maybe_put_layout(prompt)
  end

  @doc """
  Renders the prompt input area as terminal-safe text.
  """
  @spec render_text(rendered_area() | TaskPromptInput.t() | map()) :: String.t()
  def render_text(%{kind: :terminal_prompt_input_area} = area) do
    [
      "+-- #{area.title} #{layout_segment(area)} mode=#{area.input_mode}",
      "| " <> area.line,
      "+--"
    ]
    |> Enum.join("\n")
  end

  def render_text(%{id: :task_prompt} = prompt) do
    prompt
    |> render()
    |> render_text()
  end

  defp maybe_put_layout(area, %{layout: layout}) when is_map(layout) do
    Map.put(area, :layout, layout)
  end

  defp maybe_put_layout(area, _prompt), do: area

  defp layout_segment(%{layout: %{rect: rect, region: region}}) do
    "region=#{region} x=#{rect.x} y=#{rect.y} w=#{rect.width} h=#{rect.height}"
  end

  defp layout_segment(_area), do: "region=unknown"
end
