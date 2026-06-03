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
    topology = value(state, :mcp_topology, %{})
    grouped? = grouped_mcp_sessions?(state, topology)

    child_panes =
      panes
      |> Enum.filter(fn {_id, pane} -> session_pane?(pane) end)
      |> Enum.sort_by(fn {id, _pane} -> to_string(id) end)

    cond do
      grouped? ->
        child_count = grouped_child_count(state, topology)
        active_count = grouped_active_child_count(state, topology)
        IO.puts(output, "sessions: #{child_count} linked, #{active_count} active")
        render_grouped_mcp_sessions(output, state, topology)
        {:ok, %{count: child_count}}

      child_panes == [] ->
        IO.puts(output, "sessions: 0 active")
        IO.puts(output, "  no delegated work yet")

        IO.puts(
          output,
          "  start with ooo pm <goal>, ooo interview <goal>, or ooo auto <goal>"
        )

        {:ok, %{count: 0}}

      true ->
        IO.puts(output, "sessions: #{length(child_panes)} active")

        Enum.each(child_panes, fn {id, pane} ->
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

        {:ok, %{count: length(child_panes)}}
    end
  end

  defp grouped_mcp_sessions?(state, topology) do
    topology_parent_nodes(topology) != [] or
      list_value_at(state, [:parent, :working]) != [] or
      list_value_at(state, [:parent, :completed]) != []
  end

  defp render_grouped_mcp_sessions(output, state, topology) do
    parents = grouped_parent_rows(state, topology)
    wonder = value(state, :wonder, nil)

    IO.puts(output, "  #{length(parents)} MCP parent #{plural(length(parents), "call")}")

    Enum.each(parents, fn parent ->
      child_ids = grouped_child_ids(parent.parent_call_id, state, topology)
      streaming_count = Enum.count(child_ids, &(child_status(&1, state) == "streaming"))
      parallel = parallel_summary(length(child_ids), streaming_count)

      IO.puts(output, "  MCP toolcall #{parent.tool}  #{parent.status}  #{parallel}")
      IO.puts(output, "    parent #{parent.parent_call_id}  #{parent.detail}")

      Enum.each(child_ids, fn child_id ->
        status = child_status(child_id, state, wonder)
        latest = child_latest(child_id, state, wonder)
        IO.puts(output, "    #{child_id}  #{status}  #{latest}")
      end)
    end)
  end

  defp grouped_parent_rows(state, topology) do
    topology_nodes = topology_parent_nodes(topology)

    topology_parent_ids =
      topology_nodes |> Enum.map(&text_value(&1, :parent_call_id)) |> MapSet.new()

    parent_pane_nodes =
      (list_value_at(state, [:parent, :working]) ++ list_value_at(state, [:parent, :completed]))
      |> Enum.reject(&(text_value(&1, :parent_call_id) in topology_parent_ids))

    (topology_nodes ++ parent_pane_nodes)
    |> Enum.map(fn node ->
      parent_call_id = text_value(node, :parent_call_id) || "unknown-parent"
      pane = parent_pane(parent_call_id, state)

      %{
        parent_call_id: parent_call_id,
        tool: parent_tool_name(pane || node),
        status: parent_status(parent_call_id, state),
        detail: parent_detail(pane || node)
      }
    end)
  end

  defp topology_parent_nodes(topology) do
    topology
    |> value(:nodes, %{})
    |> case do
      nodes when is_map(nodes) ->
        nodes
        |> Map.values()
        |> Enum.filter(&(value(&1, :kind) == :parent_call))
        |> Enum.sort_by(
          &{value(&1, :latest_event_seq, 0), text_value(&1, :parent_call_id) || ""},
          :desc
        )

      _nodes ->
        []
    end
  end

  defp topology_child_ids(parent_call_id, topology) do
    topology
    |> value(:edges, %{})
    |> case do
      edges when is_map(edges) ->
        edges
        |> Map.values()
        |> Enum.filter(&(text_value(&1, :parent_call_id) == parent_call_id))
        |> Enum.map(&text_value(&1, :child_id))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      _edges ->
        []
    end
  end

  defp grouped_child_ids(parent_call_id, state, topology) do
    topology_ids = topology_child_ids(parent_call_id, topology)

    state_ids =
      (list_value_at(state, [:child, :working]) ++ list_value_at(state, [:child, :completed]))
      |> Enum.filter(&(text_value(&1, :parent_call_id) == parent_call_id))
      |> Enum.map(&text_value(&1, :child_id))
      |> Enum.reject(&is_nil/1)

    (topology_ids ++ state_ids)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp grouped_child_count(state, topology) do
    grouped_parent_rows(state, topology)
    |> Enum.flat_map(&grouped_child_ids(&1.parent_call_id, state, topology))
    |> Enum.uniq()
    |> length()
  end

  defp grouped_active_child_count(state, topology) do
    grouped_parent_rows(state, topology)
    |> Enum.flat_map(&grouped_child_ids(&1.parent_call_id, state, topology))
    |> Enum.uniq()
    |> Enum.count(&child_in?(state, [:child, :working], &1))
  end

  defp parent_pane(parent_call_id, state) do
    (list_value_at(state, [:parent, :working]) ++ list_value_at(state, [:parent, :completed]))
    |> Enum.find(&(text_value(&1, :parent_call_id) == parent_call_id))
  end

  defp parent_status(parent_call_id, state) do
    cond do
      Enum.any?(
        list_value_at(state, [:parent, :working]),
        &(text_value(&1, :parent_call_id) == parent_call_id)
      ) ->
        "running"

      Enum.any?(
        list_value_at(state, [:parent, :completed]),
        &(text_value(&1, :parent_call_id) == parent_call_id)
      ) ->
        "completed"

      true ->
        "linked"
    end
  end

  defp parent_tool_name(source) when is_map(source) do
    params = value(source, :params, %{})
    text_value(params, :name) || text_value(source, :method) || "tools/call"
  end

  defp parent_tool_name(_source), do: "tools/call"

  defp parent_detail(source) when is_map(source) do
    seq =
      get_in(source, [:stream_cursor, :event_seq]) ||
        value(source, :latest_event_seq) ||
        get_in(source, [:pane_state, :last_event_seq])

    event = if seq, do: "event #{seq}", else: "waiting for events"
    transport = text_value(source, :transport) || "unknown transport"
    event <> " via " <> transport
  end

  defp parent_detail(_source), do: "waiting for events"

  defp parallel_summary(0, _streaming_count), do: "no child panes yet"

  defp parallel_summary(child_count, streaming_count) do
    "#{child_count} parallel #{plural(child_count, "session")} · #{streaming_count} streaming"
  end

  defp child_status(child_id, state, wonder \\ nil) do
    cond do
      wonder_child?(wonder, child_id) -> "waiting permission"
      child_in?(state, [:child, :working], child_id) -> "streaming"
      child_in?(state, [:child, :completed], child_id) -> "completed"
      true -> "linked"
    end
  end

  defp child_latest(child_id, state, wonder) do
    cond do
      wonder_child?(wonder, child_id) ->
        "permission: " <> wonder_description(wonder)

      pane = child_pane(child_id, state) ->
        child_pane_latest(pane)

      true ->
        "linked to parent"
    end
  end

  defp child_in?(state, path, child_id) do
    state
    |> list_value_at(path)
    |> Enum.any?(&(text_value(&1, :child_id) == child_id))
  end

  defp child_pane(child_id, state) do
    (list_value_at(state, [:child, :working]) ++ list_value_at(state, [:child, :completed]))
    |> Enum.find(&(text_value(&1, :child_id) == child_id))
  end

  defp child_pane_latest(pane) do
    text_value(pane, :last_line) ||
      text_value(pane, :line) ||
      text_value(pane, :summary) ||
      latest_stream_entry_text(pane) ||
      text_value(pane, :title) ||
      "stream open"
  end

  defp latest_stream_entry_text(pane) do
    pane
    |> get_in([:pane_state, :stream_entries])
    |> case do
      entries when is_list(entries) ->
        entries
        |> List.last()
        |> stream_entry_text()

      _entries ->
        nil
    end
  end

  defp stream_entry_text(entry) when is_map(entry) do
    entry_text(entry, :token) ||
      entry_text(entry, :delta) ||
      entry_text(entry, :content)
  end

  defp stream_entry_text(_entry), do: nil

  defp entry_text(entry, key) do
    case value(entry, key) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp wonder_child?(wonder, child_id) when is_map(wonder) do
    text_value(wonder, :child_id) == child_id
  end

  defp wonder_child?(_wonder, _child_id), do: false

  defp wonder_description(wonder) when is_map(wonder) do
    text_value(wonder, :description) ||
      get_in(wonder, [:request, :description]) ||
      get_in(wonder, ["request", "description"]) ||
      text_value(wonder, :request_id) ||
      "user decision needed"
  end

  defp wonder_description(_wonder), do: "user decision needed"

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
    IO.puts(output, "+-- State")
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
    workspace = WorkspaceModel.build("/plugins", state, %{})
    plugin_count = workspace |> value(:records, []) |> length()

    IO.puts(output, "plugins: #{plugin_count} available")
    IO.puts(output, WorkspaceText.render(workspace))

    {:ok,
     %{
       status: :rendered,
       workspace: workspace,
       plugin_count: plugin_count,
       count: plugin_count
     }}
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

  defp text_value(map, key) when is_map(map) do
    case value(map, key) do
      nil -> nil
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp text_value(_map, _key), do: nil

  defp list_value_at(map, path) when is_map(map) and is_list(path) do
    case get_in(map, path) do
      list when is_list(list) -> list
      _value -> []
    end
  end

  defp list_value_at(_map, _path), do: []

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

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
