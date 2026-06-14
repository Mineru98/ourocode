defmodule Ourocode.Terminal.ShellRenderer do
  @moduledoc """
  Initial terminal frame renderer for the interactive shell.

  This module is deliberately pure apart from `draw_initial_frame/2`: it
  consumes the dashboard prompt plus runtime pane model and turns them into the
  first shell frame a terminal user sees before the persistent prompt loop takes
  over.
  """

  alias Ourocode.Terminal.PluginStatusArea

  @doc """
  Writes the first terminal baseline frame to the given IO device.
  """
  @spec draw_initial_frame(map(), atom() | pid()) :: :ok
  def draw_initial_frame(startup_result, device \\ :stdio) when is_map(startup_result) do
    IO.write(device, render_initial_frame(startup_result) <> "\n")
  end

  @doc """
  Renders the initial interactive prompt and pane state as terminal-safe text.
  """
  @spec render_initial_frame(map()) :: String.t()
  def render_initial_frame(%{status: :healthy, context: _context, panes: panes} = startup_result) do
    [
      "ourocode agent",
      "status: #{status_label(startup_result)}   project: #{project_label(startup_result)}",
      "",
      "Start here:",
      "  ooo pm <goal>        product requirements with answer choices",
      "  ooo interview <goal> clarify decisions through questions",
      "  ooo auto <goal>      plan, verify, then execute",
      "",
      "Ready:",
      "  model: codex  (ChatGPT)",
      "  #{plugin_summary(startup_result)}",
      "  live verify: ourocode --verify --format json --project-dir .",
      "  safety preview: /preflight <command>",
      "  active work: /sessions",
      "",
      "Automation:",
      "  ourocode --verify --format json --project-dir .",
      "  ourocode --prompt \"summarize this repo\" --format json",
      "",
      "Prompt: #{prompt_value(startup_result)}",
      "Mode: #{layout_mode(panes)}   Focus: #{focused_pane(panes)}"
    ]
    |> Enum.join("\n")
  end

  def render_initial_frame(%{status: status}) do
    "ourocode agent\nstatus: #{status}"
  end

  defp layout_mode(%{layout: %{mode: mode}}), do: mode
  defp layout_mode(_panes), do: :unknown

  defp focused_pane(%{task_prompt: %{focused?: true}}), do: :task_prompt
  defp focused_pane(%{focused: focused}) when not is_nil(focused), do: focused
  defp focused_pane(_panes), do: :none

  defp status_label(%{status: status, runtime: %{status: runtime_status}}) do
    "#{status} / #{runtime_status}"
  end

  defp status_label(%{status: status}), do: to_string(status)

  defp project_label(%{context: %{project_dir: project_dir}}) when is_binary(project_dir) do
    Path.basename(project_dir)
  end

  defp project_label(_startup_result), do: "current directory"

  defp plugin_summary(startup_result) do
    area = PluginStatusArea.render(startup_result)

    case area.items do
      [] ->
        "none configured"

      items ->
        items
        |> Enum.map(fn item -> "#{item.plugin_id} #{item.state_label}" end)
        |> Enum.join(", ")
    end
  end

  defp prompt_value(%{context: %{initial_task_request: %{task_input: task_input}}})
       when is_binary(task_input) do
    task_input
  end

  defp prompt_value(%{panes: %{task_prompt: %{value: value}}}) when is_binary(value) do
    case String.trim(value) do
      "" -> "Describe a task for a new session"
      prompt -> prompt
    end
  end

  defp prompt_value(_startup_result), do: "Describe a task for a new session"
end
