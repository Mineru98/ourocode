defmodule Ourocode.Terminal.ShellRenderer do
  @moduledoc """
  Initial terminal frame renderer for the interactive shell.

  This module is deliberately pure apart from `draw_initial_frame/2`: it
  consumes the dashboard prompt plus runtime pane model and turns them into the
  first shell frame a terminal user sees before the persistent prompt loop takes
  over.
  """

  alias Ourocode.Dashboard.{ChildSessionPanes, Layout, ParentMcpPane}

  alias Ourocode.Terminal.{
    HeaderStatusArea,
    ParentChildPaneArea,
    PluginStatusArea,
    PromptFooterLayout
  }

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
      render_header_status(startup_result),
      "mode=#{layout_mode(panes)} focus=#{focused_pane(panes)}",
      "",
      render_parent_child_pane_area(startup_result),
      "",
      render_plugin_status_area(startup_result),
      "",
      render_prompt_footer_layout(startup_result)
    ]
    |> Enum.join("\n")
  end

  def render_initial_frame(%{status: status}) do
    HeaderStatusArea.render_text(HeaderStatusArea.render(%{status: status}))
  end

  defp render_header_status(%{context: context} = startup_result) do
    startup_result
    |> Map.put(:runtime, Map.get(startup_result, :runtime) || Map.get(context, :runtime))
    |> HeaderStatusArea.render()
    |> HeaderStatusArea.render_text()
  end

  defp render_parent_child_pane_area(startup_result) do
    startup_result
    |> runtime_hierarchy()
    |> ParentChildPaneArea.render()
    |> ParentChildPaneArea.render_text()
  end

  defp render_plugin_status_area(startup_result) do
    startup_result
    |> PluginStatusArea.render()
    |> PluginStatusArea.render_text()
  end

  defp render_prompt_footer_layout(startup_result) do
    startup_result
    |> PromptFooterLayout.render()
    |> PromptFooterLayout.render_text()
  end

  defp layout_mode(%{layout: %{mode: mode}}), do: mode
  defp layout_mode(_panes), do: :unknown

  defp focused_pane(%{task_prompt: %{focused?: true}}), do: :task_prompt
  defp focused_pane(%{focused: focused}) when not is_nil(focused), do: focused
  defp focused_pane(_panes), do: :none

  defp runtime_hierarchy(%{parent_child_hierarchy: %{id: :mcp_runtime_hierarchy} = hierarchy}) do
    hierarchy
  end

  defp runtime_hierarchy(%{runtime: %{parent_panes: parent_state, child_panes: child_state}}) do
    Layout.parent_child_hierarchy(parent_state, child_state)
  end

  defp runtime_hierarchy(%{
         context: %{runtime: %{parent_panes: parent_state, child_panes: child_state}}
       }) do
    Layout.parent_child_hierarchy(parent_state, child_state)
  end

  defp runtime_hierarchy(_startup_result) do
    Layout.parent_child_hierarchy(ParentMcpPane.new(), ChildSessionPanes.new())
  end
end
