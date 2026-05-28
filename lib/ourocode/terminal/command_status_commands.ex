defmodule Ourocode.Terminal.CommandStatusCommands do
  @moduledoc """
  Read-only slash-command renderers for runtime and terminal status.
  """

  alias Ourocode.Terminal.FooterStateArea
  alias Ourocode.Terminal.PluginStatusArea
  alias Ourocode.Terminal.WorkspaceModel
  alias Ourocode.Terminal.WorkspaceText

  @actions [
    :show_status,
    :show_plugins,
    :show_mcp,
    :show_mcps,
    :show_sandbox,
    :show_agents,
    :show_children,
    :show_sessions,
    :show_config,
    :show_queue,
    :show_hooks,
    :show_wonder_tool
  ]

  @stub_messages %{
    show_queue: {"queue", "queued notifications are shown near the prompt"},
    show_hooks: {"hooks", "recent automation activity appears near the prompt"},
    show_wonder_tool: {"questions", "active questions render in the interaction area"}
  }

  @type action ::
          :show_status
          | :show_plugins
          | :show_mcp
          | :show_mcps
          | :show_sandbox
          | :show_agents
          | :show_children
          | :show_sessions
          | :show_config
          | :show_queue
          | :show_hooks
          | :show_wonder_tool

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec render(action(), map()) :: {:ok, map()}
  def render(:show_status, state) do
    render_product_status(state.output, state)
    render_sessions(state.output, state)
    {:ok, %{status: :rendered}}
  end

  def render(:show_plugins, state) do
    render_plugins(state.output, state)
  end

  def render(:show_sessions, state) do
    render_sessions(state.output, state)
  end

  def render(:show_agents, state) do
    render_workspace(state.output, state, "/agents")
  end

  def render(:show_children, state) do
    render_sessions(state.output, state)
  end

  def render(:show_config, state) do
    render_workspace(state.output, state, "/config")
  end

  def render(:show_mcp, state) do
    render_workspace(state.output, state, "/mcp")
  end

  def render(:show_mcps, state) do
    render_workspace(state.output, state, "/mcps")
  end

  def render(:show_sandbox, state) do
    render_workspace(state.output, state, "/sandbox")
  end

  def render(action, state) when is_map_key(@stub_messages, action) do
    {label, message} = Map.fetch!(@stub_messages, action)
    render_stub(state.output, label, message)
  end

  @spec render_sessions(pid(), map()) :: {:ok, map()}
  def render_sessions(output, state) when is_map(state) do
    panes = get_in(state, [:pane_model, :panes]) || %{}

    child_panes =
      panes
      |> Enum.filter(fn {_id, pane} -> session_pane?(pane) end)
      |> Enum.sort_by(fn {id, _pane} -> to_string(id) end)

    IO.puts(output, "sessions: #{length(child_panes)} active")

    case child_panes do
      [] ->
        IO.puts(output, "  no delegated work yet")
        IO.puts(
          output,
          "  start with ooo pm <goal>, ooo interview <goal>, or ooo auto <goal>"
        )

      panes ->
        Enum.each(panes, fn {id, pane} ->
          session_id = value(pane, :child_id) || value(pane, :session_id) || id
          status = value(pane, :status) || value(pane, :state) || "active"
          task = value(pane, :task) || value(pane, :title) || value(pane, :label) || "working"
          recent = value(pane, :line) || value(pane, :last_line) || value(pane, :summary)

          IO.puts(output, "  #{id}  #{status}  #{task}")
          IO.puts(output, "    target #{session_id}")

          if is_binary(recent) and String.trim(recent) != "" do
            IO.puts(output, "    last #{String.trim(recent)}")
          end
        end)
    end

    {:ok, %{count: length(child_panes)}}
  end

  defp render_workspace(output, state, command) do
    workspace = WorkspaceModel.build(command, state, %{})
    IO.puts(output, WorkspaceText.render(workspace))

    {:ok,
     %{
       status: :rendered,
       workspace: workspace,
       plugin_count: workspace |> value(:records, []) |> length(),
       count: workspace |> value(:records, []) |> active_agent_count(command)
     }}
  end

  defp render_product_status(output, state) do
    area = PluginStatusArea.render(state |> value(:startup_result, state))
    footer = FooterStateArea.render(state |> value(:startup_result, state))

    ready? = area.plugin_count > 0
    active_sessions = session_count(state)
    queue_count = Map.get(footer, :queued_count, 0)

    IO.puts(output, "status")
    IO.puts(output, "  app #{if ready?, do: "ready", else: "needs setup"}")
    IO.puts(output, "  tools #{area.plugin_count} connected")
    IO.puts(output, "  active work #{active_sessions}")
    IO.puts(output, "  queue #{queue_count}")
    IO.puts(output, "  next ooo pm <goal>, ooo interview <goal>, ooo auto <goal>, or /verify")
  end

  defp session_count(state) do
    state
    |> get_in([:pane_model, :panes])
    |> case do
      panes when is_map(panes) -> Enum.count(panes, fn {_id, pane} -> session_pane?(pane) end)
      _other -> 0
    end
  end

  @spec render_config(pid(), map()) :: {:ok, map()}
  def render_config(output, state) when is_map(state) do
    area = PluginStatusArea.render(state |> value(:startup_result, state))

    IO.puts(output, "config workspace")
    IO.puts(output, "  status #{if(area.plugin_count > 0, do: "ready", else: "needs setup")}")
    IO.puts(output, "  scope project")
    IO.puts(output, "  source .ourocode/plugins.json or plugin manifest")
    IO.puts(output, "  records #{area.plugin_count} plugin config")

    case area.items do
      [] ->
        IO.puts(output, "  record plugin-config")
        IO.puts(output, "    state missing")
        IO.puts(output, "    risk guided work unavailable")
        IO.puts(output, "    action add official plugin, then /reload")

      items ->
        Enum.each(items, fn item ->
          render_plugin_record(output, item, "config")
        end)

        if Enum.any?(items, &(&1.state_label in ["needs attention", "not ready"])) do
          IO.puts(output, "  next fix plugin setup, then run /reload")
        else
          IO.puts(output, "  next run ooo pm <goal> or /verify")
        end
    end

    IO.puts(output, "  actions /plugins inspect, /reload apply, /verify test")
    {:ok, %{status: :rendered, plugin_count: area.plugin_count}}
  end

  @spec render_connection_status(pid(), map()) :: {:ok, map()}
  def render_connection_status(output, state) when is_map(state) do
    area =
      state
      |> value(:startup_result, state)
      |> PluginStatusArea.render()

    IO.puts(output, "mcps workspace")

    IO.puts(
      output,
      "  status #{if(area.plugin_count > 0, do: "connected", else: "not configured")}"
    )

    IO.puts(output, "  transport local plugin bridge")
    IO.puts(output, "  records #{area.plugin_count} server connection")

    case area.items do
      [] ->
        IO.puts(output, "  record official-plugin")
        IO.puts(output, "    state not configured")
        IO.puts(output, "    tools 0 loaded")
        IO.puts(output, "    permissions none")
        IO.puts(output, "    action add plugin, /reload, inspect errors")

      items ->
        Enum.each(items, fn item ->
          IO.puts(output, "  record #{item.plugin_id}")
          IO.puts(output, "    state #{item.state_label}  #{version_text(item)}")
          IO.puts(output, "    source #{item.source_badge} #{source_text(item)}")
          IO.puts(output, "    tools commands, skills, guided work")
          IO.puts(output, "    permissions workspace read/write, reviewed commands")
          IO.puts(output, "    health #{plugin_health(item)}")
          IO.puts(output, "    actions /plugins inspect, /skills list, /verify test")
        end)
    end

    IO.puts(output, "  verify ./ourocode --verify --format json --project-dir .")
    {:ok, %{status: :rendered, plugin_count: area.plugin_count}}
  end

  @spec render_sandbox_status(pid(), map()) :: {:ok, map()}
  def render_sandbox_status(output, _state) do
    IO.puts(output, "sandbox workspace")
    IO.puts(output, "  status guarded")
    IO.puts(output, "  mode project workspace")
    IO.puts(output, "  records 4 controls")
    IO.puts(output, "  record writable-roots")
    IO.puts(output, "    allow project directory")
    IO.puts(output, "    deny parent-directory, symlink escape, null-byte")
    IO.puts(output, "    action /preflight <command>")
    IO.puts(output, "  record network")
    IO.puts(output, "    default off for local inspection")
    IO.puts(output, "    action request intent before external calls")
    IO.puts(output, "  record shell")
    IO.puts(output, "    deny shell expansion and backslash escape")
    IO.puts(output, "    action review command before execution")
    IO.puts(output, "  record recovery")
    IO.puts(output, "    action /cancel stop active interview or delegated work")
    IO.puts(output, "    verify /verify")
    IO.puts(output, "  evidence router sandbox tests and ./ourocode --verify")
    {:ok, %{status: :rendered}}
  end

  @spec render_plugins(pid(), map()) :: {:ok, map()}
  def render_plugins(output, state) when is_map(state) do
    render_workspace(output, state, "/plugins")
  end

  @spec render_stub(pid(), String.t(), String.t()) :: {:ok, map()}
  def render_stub(output, label, message) do
    IO.puts(output, "#{label}: #{message}")
    {:ok, %{status: :rendered}}
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_map, _key, default), do: default

  defp active_agent_count(records, "/agents") when is_list(records) do
    Enum.count(records, fn record ->
      record
      |> value(:id, "")
      |> to_string()
      |> String.starts_with?("agent:active:")
    end)
  end

  defp active_agent_count(records, _command) when is_list(records), do: length(records)
  defp active_agent_count(_records, _command), do: 0

  defp session_pane?(pane) do
    value(pane, :kind) in [:child_session, "child_session", :workflow_session, "workflow_session"]
  end

  defp version_text(%{version_label: "version pending"}), do: "version pending"
  defp version_text(%{version_label: label}) when is_binary(label), do: "version " <> label
  defp version_text(_item), do: "version pending"

  defp source_text(%{source_label: label}) when is_binary(label), do: label
  defp source_text(_item), do: "managed plugin"

  defp render_plugin_record(output, item, kind) do
    IO.puts(output, "  record #{item.plugin_id}")
    IO.puts(output, "    type #{kind}  state #{item.state_label}  #{version_text(item)}")
    IO.puts(output, "    trust #{item.source_badge} #{source_text(item)}")
    IO.puts(output, "    location #{plugin_location(item)}")
    IO.puts(output, "    capabilities commands, skills, guided work")
    IO.puts(output, "    health #{plugin_health(item)}")
    IO.puts(output, "    actions inspect /plugins, reload /reload, test /verify")
  end

  defp plugin_health(%{state_label: state}) when state in ["loaded", "enabled", "ready to load"],
    do: "ready"

  defp plugin_health(%{state_label: "disabled"}), do: "disabled"
  defp plugin_health(_item), do: "needs attention"

  defp plugin_location(%{source_type: "official"}), do: "official bundle"
  defp plugin_location(%{source_type: "third_party"}), do: "configured package"
  defp plugin_location(_item), do: "configured plugin"
end
