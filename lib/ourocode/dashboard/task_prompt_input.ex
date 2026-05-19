defmodule Ourocode.Dashboard.TaskPromptInput do
  @moduledoc """
  Data-only projection for the natural-language task prompt.

  The dashboard starts in chat/task-input mode. This pane represents an empty,
  focused text entry field so terminal renderers can show a compact prompt
  without routing the user through runtime commands.
  """

  @default_placeholder "Describe a task for a new session"

  @type t :: %{
          required(:id) => :task_prompt,
          required(:kind) => :natural_language_task_input,
          required(:title) => String.t(),
          required(:placeholder) => String.t(),
          required(:value) => String.t(),
          required(:cursor_position) => non_neg_integer(),
          required(:focused?) => boolean(),
          required(:editable?) => boolean(),
          required(:representative_ux) => :natural_language_task_input,
          required(:submit_action) => :start_session,
          optional(:layout) => map()
        }

  @doc """
  Renders the initial prompt state for natural-language task entry.
  """
  @spec render(keyword() | map()) :: t()
  def render(options \\ []) do
    options = Map.new(options)
    value = Map.get(options, :value, "")

    %{
      id: :task_prompt,
      kind: :natural_language_task_input,
      title: "Task",
      placeholder: Map.get(options, :placeholder, @default_placeholder),
      value: value,
      cursor_position: cursor_position(value, Map.get(options, :cursor_position, 0)),
      focused?: Map.get(options, :focused?, true),
      editable?: Map.get(options, :editable?, true),
      representative_ux: :natural_language_task_input,
      submit_action: :start_session
    }
  end

  @doc """
  Formats the prompt as a compact terminal line.
  """
  @spec render_line(t()) :: String.t()
  def render_line(%{value: "", placeholder: placeholder}) do
    "> " <> placeholder
  end

  def render_line(%{value: value}) when is_binary(value) do
    "> " <> value
  end

  @doc """
  Converts the prompt value into a natural-language task request.
  """
  @spec submit(t(), keyword() | map()) :: {:ok, Ourocode.TaskRequest.t()} | {:error, String.t()}
  def submit(%{value: value}, options \\ []) when is_binary(value) do
    options =
      options
      |> Map.new()
      |> Map.put_new(:source, :dashboard)

    Ourocode.TaskRequest.parse(value, options)
  end

  defp cursor_position(value, requested) when is_binary(value) and is_integer(requested) do
    requested
    |> max(0)
    |> min(String.length(value))
  end

  defp cursor_position(value, _requested) when is_binary(value), do: String.length(value)
end
