defmodule Ourocode.Terminal.CommandStatusCommands do
  @moduledoc """
  Read-only slash-command renderers for runtime and terminal status.
  """

  alias Ourocode.Terminal.FooterStateArea
  alias Ourocode.Terminal.PluginStatusArea

  @actions [
    :show_status,
    :show_plugins,
    :show_mcp,
    :show_sessions,
    :show_config,
    :show_queue,
    :show_hooks,
    :show_wonder_tool
  ]

  @stub_messages %{
    show_mcp: {"mcp", "stdio,SSE,streamable_http"},
    show_config: {"config", "plugin/runtime config; use /reload to reload"},
    show_queue: {"queue", "queued notifications are shown near the prompt"},
    show_hooks: {"hooks", "hook lifecycle activity is in the footer/status area"},
    show_wonder_tool: {"wonderTool", "active questions render in the interaction area"}
  }

  @type action ::
          :show_status
          | :show_plugins
          | :show_mcp
          | :show_sessions
          | :show_config
          | :show_queue
          | :show_hooks
          | :show_wonder_tool

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec render(action(), map()) :: {:ok, map()}
  def render(:show_status, state) do
    IO.puts(state.output, FooterStateArea.render_text(state.startup_result))
    IO.puts(state.output, PluginStatusArea.render_text(state.startup_result))
    render_sessions(state.output, state)
    {:ok, %{status: :rendered}}
  end

  def render(:show_plugins, state) do
    IO.puts(state.output, PluginStatusArea.render_text(state.startup_result))
    {:ok, %{status: :rendered}}
  end

  def render(:show_sessions, state) do
    render_sessions(state.output, state)
  end

  def render(action, state) when is_map_key(@stub_messages, action) do
    {label, message} = Map.fetch!(@stub_messages, action)
    render_stub(state.output, label, message)
  end

  @spec render_sessions(pid(), map()) :: {:ok, map()}
  def render_sessions(output, state) when is_map(state) do
    panes = get_in(state, [:pane_model, :panes]) || %{}
    IO.puts(output, "sessions:")

    panes
    |> Enum.filter(fn {_id, pane} -> Map.get(pane, :kind) == :child_session end)
    |> Enum.each(fn {id, pane} ->
      session_id = Map.get(pane, :child_id) || Map.get(pane, :session_id) || id
      IO.puts(output, "  #{id} session=#{session_id}")
    end)

    {:ok, %{count: map_size(panes)}}
  end

  @spec render_stub(pid(), String.t(), String.t()) :: {:ok, map()}
  def render_stub(output, label, message) do
    IO.puts(output, "#{label}: #{message}")
    {:ok, %{status: :rendered}}
  end
end
