defmodule Ourocode.Terminal.WorkspaceModel do
  @moduledoc false

  alias Ourocode.Command.Registry, as: CommandRegistry
  alias Ourocode.Terminal.{InterviewLiveState, PluginStatusArea, ResumeSessions}

  @management_commands ~w(/plugins /mcps /mcp /config /sandbox /agents /sessions /children /resume)

  @spec management_command?(term()) :: boolean()
  def management_command?(command), do: command in @management_commands

  @spec workflow_start(String.t()) :: map()
  def workflow_start(line) when is_binary(line) do
    mode = workflow_mode(line)
    record = workflow_start_record(mode, line)

    %{
      kind: "workflow",
      title: workflow_start_title(mode),
      status: workflow_start_status(mode),
      selected: record.id,
      records: [record],
      detail: record,
      actions: workflow_start_actions(mode),
      shortcuts: workspace_shortcuts("Enter focus"),
      next: workflow_start_next(mode)
    }
  end

  @spec build(String.t(), map(), map()) :: map() | nil
  def build(command, state, command_result \\ %{})

  def build("/plugins", state, _command_result), do: plugin_workspace(state)
  def build("/mcps", state, _command_result), do: mcp_workspace(state)
  def build("/mcp", state, command_result), do: build("/mcps", state, command_result)
  def build("/config", state, _command_result), do: config_workspace(state)
  def build("/sandbox", _state, _command_result), do: sandbox_workspace()
  def build("/agents", state, _command_result), do: agents_workspace(state)

  def build(command, state, command_result) when command in ["/sessions", "/children"],
    do: sessions_workspace(state, command_result)

  def build("/resume", state, command_result), do: resume_workspace(state, command_result)
  def build(_command, _state, _command_result), do: nil

  defp plugin_workspace(state) do
    area = plugin_area(state)
    records = Enum.map(area.items, &plugin_record(&1, "plugin"))

    %{
      kind: "plugins",
      title: "Plugins",
      status: if(records == [], do: "empty", else: "ready"),
      selected: selected_id(records),
      records: records,
      detail: selected_detail(records, "No plugin configured."),
      actions: [
        action("connections", "Show MCP connections", "/mcp", "m"),
        action("verify", "Run health checks", "/verify", "v")
      ],
      shortcuts: workspace_shortcuts("Enter inspect"),
      next:
        if(records == [],
          do: "Install the official plugin, then reload.",
          else: "Start with ooo pm <goal>; use /verify for a health check."
        )
    }
  end

  defp mcp_workspace(state) do
    area = plugin_area(state)

    plugin_records =
      Enum.map(area.items, fn item ->
        %{
          id: "mcp:" <> item.plugin_id,
          title: plugin_display_title(item),
          state: item.state_label,
          health: plugin_health(item),
          fields: %{
            source: item.source_label,
            workflows: ["commands", "skills", "guided work"],
            access: ["workspace read/write", "reviewed commands"]
          },
          actions: [
            action("inspect", "Inspect plugin", "/plugins", "i"),
            action("skills", "List skills", "/skills", "s"),
            action("verify", "Test connection", "/verify", "v")
          ]
        }
      end)

    topology_records = mcp_topology_records(state)
    records = topology_records ++ plugin_records ++ mcp_tool_records(state)

    %{
      kind: "mcps",
      title: "Connected tools",
      status: if(records == [], do: "not configured", else: "connected"),
      selected: selected_id(records),
      records: records,
      detail: selected_detail(records, "No connected tool configured."),
      actions: mcp_workspace_actions(topology_records),
      shortcuts: workspace_shortcuts("Enter inspect"),
      next:
        if(records == [],
          do: "Add the official tool, then reload.",
          else: "Watch live MCP calls here; /sessions shows every linked child pane."
        )
    }
  end

  defp config_workspace(state) do
    area = plugin_area(state)
    records = Enum.map(area.items, &plugin_record(&1, "config"))

    %{
      kind: "config",
      title: "Configuration",
      status: if(records == [], do: "needs setup", else: "ready"),
      selected: selected_id(records),
      records: records,
      detail: selected_detail(records, "No project plugin config found."),
      actions: [
        action("plugins", "Inspect plugins", "/plugins", "p"),
        action("reload", "Reload config", "/reload", "r"),
        action("verify", "Test config", "/verify", "v")
      ],
      shortcuts: workspace_shortcuts("Enter inspect"),
      next:
        if(records == [],
          do: "Create plugin config, then /reload.",
          else: "Start with ooo pm <goal>; use /verify for a health check."
        )
    }
  end

  defp sandbox_workspace do
    records = [
      control_record(
        "writable-roots",
        "Writable Roots",
        "guarded",
        ["allow project directory", "deny parent-directory", "deny symlink escape"],
        "/preflight <command>"
      ),
      control_record(
        "network",
        "Network",
        "review required",
        ["default off for local inspection", "external calls need intent"],
        "/preflight <command>"
      ),
      control_record(
        "shell",
        "Shell",
        "review required",
        ["deny shell expansion", "deny backslash escape"],
        "/preflight <command>"
      ),
      control_record(
        "recovery",
        "Recovery",
        "ready",
        ["cancel active interview", "verify product checks"],
        "/cancel"
      )
    ]

    %{
      kind: "sandbox",
      title: "Sandbox",
      status: "guarded",
      selected: selected_id(records),
      records: records,
      detail: selected_detail(records, "No control selected."),
      actions: [
        action("preflight", "Inspect command", "/preflight <command>", "p"),
        action("verify", "Verify safeguards", "/verify", "v"),
        action("cancel", "Stop active work", "/cancel", "x")
      ],
      shortcuts: workspace_shortcuts("Enter inspect"),
      next: "Run /preflight <command> before risky execution."
    }
  end

  defp agents_workspace(state) do
    active_records =
      state
      |> pane_model()
      |> agent_panes()
      |> Enum.map(fn {id, pane} -> agent_record(id, pane) end)
      |> sort_agent_records()
      |> maybe_add_live_interview_record(state)

    records =
      case active_records do
        [] -> default_agent_records()
        records -> records
      end

    active_count =
      records
      |> Enum.count(fn record ->
        value(record, :id, "")
        |> to_string()
        |> String.starts_with?("agent:active:")
      end)

    %{
      kind: "agents",
      title: "Guided work",
      status: agent_workspace_status(active_count),
      selected: selected_id(records),
      records: records,
      detail: selected_detail(records, "No active work selected."),
      actions: agent_workspace_actions(active_count),
      shortcuts: workspace_shortcuts("Enter focus"),
      next: agent_workspace_next(active_count)
    }
  end

  defp pane_model(state), do: get_in(state, [:pane_model, :panes]) || %{}

  defp agent_panes(panes) when is_map(panes) do
    panes
    |> Enum.filter(fn {_id, pane} -> session_pane?(pane) end)
    |> Enum.sort_by(fn {id, _pane} -> to_string(id) end)
  end

  defp agent_panes(_panes), do: []

  defp sort_agent_records(records) do
    Enum.sort_by(records, fn record ->
      id = value(record, :id, "") |> to_string()
      {agent_record_priority(id), id}
    end)
  end

  defp agent_record_priority("agent:active:" <> _rest), do: 0
  defp agent_record_priority("agent:attention:" <> _rest), do: 1
  defp agent_record_priority("agent:stopped:" <> _rest), do: 2
  defp agent_record_priority(_id), do: 3

  defp session_pane?(pane) do
    value(pane, :kind) in [:child_session, "child_session", :workflow_session, "workflow_session"]
  end

  defp agent_record(id, pane) do
    id = to_string(id)
    status = text_value(pane, :status) || text_value(pane, :state) || "active"
    lane_group = agent_lane_group(status)

    task =
      text_value(pane, :task) || text_value(pane, :title) || text_value(pane, :label) || "working"

    current =
      text_value(pane, :current) || text_value(pane, :line) || text_value(pane, :last_line) ||
        text_value(pane, :summary)

    current = user_current(current)

    elapsed = text_value(pane, :elapsed) || text_value(pane, :elapsed_label) || "live"

    %{
      id: lane_group <> ":" <> id,
      title: agent_title(id, pane),
      state: status,
      health: agent_health(status),
      fields: %{
        step: text_value(pane, :phase) || agent_phase(status),
        task: task,
        current: current || "waiting for output",
        progress: agent_progress(status, pane),
        elapsed: elapsed,
        controls: list_value(pane, :controls) || agent_controls(status),
        activity: agent_activity(status, pane)
      },
      actions: [
        action("focus", "Focus work", "/pane #{id}", "Enter"),
        action("sessions", "Inspect sessions", "/sessions", "s"),
        action("cancel", "Cancel", "/cancel", "x")
      ]
    }
  end

  defp maybe_add_live_interview_record(records, state) do
    case live_interview_record(state) do
      nil -> records
      record -> Enum.uniq_by([record | records], &value(&1, :id))
    end
  end

  defp live_interview_record(state) do
    result = value(state, :startup_result, %{})

    with %{} = interview <- InterviewLiveState.interview(result),
         false <- Map.get(interview, :complete, false) == true do
      session = InterviewLiveState.interview_session(result) || %{}
      paused? = InterviewLiveState.paused?(result)
      waiting? = Map.get(interview, :waiting, false) == true
      status = live_interview_status(interview, paused?, waiting?)
      phase = live_interview_phase(paused?, waiting?)

      %{
        id: "agent:active:interview",
        title: "PM interview",
        state: status,
        health: agent_health(status),
        fields: %{
          step: phase,
          task: Map.get(session, :label, "ooo pm interview"),
          current: live_interview_current(interview, paused?, waiting?),
          progress: live_interview_progress(interview, paused?, waiting?),
          target:
            Map.get(interview, :session_id) || Map.get(session, :parent_call_id) || "main session",
          elapsed: if(waiting?, do: "building choices", else: "live"),
          controls: live_interview_controls(paused?, waiting?),
          activity: live_interview_activity(interview, session)
        },
        actions: [
          action("answer", "Answer", "/answer <text>", "Enter"),
          action("sessions", "Inspect sessions", "/sessions", "s"),
          action("cancel", "Cancel", "/cancel", "x")
        ]
      }
    else
      _other -> nil
    end
  end

  defp live_interview_status(_interview, true, _waiting?), do: "paused"
  defp live_interview_status(_interview, _paused?, true), do: "waiting"
  defp live_interview_status(_interview, _paused?, _waiting?), do: "asking"

  defp live_interview_phase(true, _waiting?), do: "paused for discussion"
  defp live_interview_phase(_paused?, true), do: "generating answer choices"
  defp live_interview_phase(_paused?, _waiting?), do: "awaiting user answer"

  defp live_interview_current(interview, true, _waiting?) do
    question = Map.get(interview, :question, "")

    case String.trim(to_string(question || "")) do
      "" -> "paused; /answer resumes"
      text -> text
    end
  end

  defp live_interview_current(interview, _paused?, true) do
    Map.get(interview, :status) || "building next answer choices"
  end

  defp live_interview_current(interview, _paused?, _waiting?) do
    Map.get(interview, :question) || Map.get(interview, :status) || "waiting for answer"
  end

  defp live_interview_progress(_interview, true, _waiting?) do
    ["question preserved", "main composer open", "/answer resumes"]
  end

  defp live_interview_progress(_interview, _paused?, true) do
    ["answer accepted", "remote session running", "choices pending"]
  end

  defp live_interview_progress(interview, _paused?, _waiting?) do
    count = interview |> Map.get(:question_options, []) |> List.wrap() |> length()

    if count > 0 do
      ["#{count} choices visible", "number keys select", "Enter confirms"]
    else
      ["question visible", "custom answer ready", "Esc pauses"]
    end
  end

  defp live_interview_controls(true, _waiting?), do: ["/answer <text>", "/cancel", "/sessions"]
  defp live_interview_controls(_paused?, true), do: ["Esc pause", "/cancel", "/sessions"]

  defp live_interview_controls(_paused?, _waiting?),
    do: ["1-9 select", "type custom", "Esc pause"]

  defp live_interview_activity(interview, session) do
    [
      evidence_part("round", Map.get(session, :round)),
      if(Map.get(interview, :session_id), do: "session linked"),
      if(Map.get(interview, :parent_call_id) || Map.get(session, :parent_call_id),
        do: "parent session linked"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ["live render state"]
      parts -> parts
    end
  end

  defp evidence_part(_label, nil), do: nil
  defp evidence_part(_label, ""), do: nil
  defp evidence_part(label, value), do: "#{label} #{value}"

  defp default_agent_records do
    [
      %{
        id: "agent:ready:pm-interview",
        title: "PM interview",
        state: "ready",
        health: "ready",
        fields: %{
          task: "start with ooo pm <goal>",
          current: "product requirements with answer choices",
          controls: ["start", "inspect sessions", "cancel"],
          target: "main session"
        },
        actions: [
          action("start", "Start PM interview", "ooo pm <goal>", "Enter"),
          action("sessions", "Inspect sessions", "/sessions", "s")
        ]
      },
      %{
        id: "agent:ready:interview",
        title: "Interview",
        state: "ready",
        health: "ready",
        fields: %{
          task: "start with ooo interview <goal>",
          current: "clarify requirements through questions",
          controls: ["start", "inspect sessions", "cancel"],
          target: "main session"
        },
        actions: [
          action("start", "Start interview", "ooo interview <goal>", "Enter"),
          action("sessions", "Inspect sessions", "/sessions", "s")
        ]
      },
      %{
        id: "agent:ready:auto",
        title: "Auto workflow",
        state: "ready",
        health: "ready",
        fields: %{
          task: "start with ooo auto <goal>",
          current: "interview, draft a plan, then request approval",
          controls: ["start", "inspect agents", "cancel"],
          target: "main session"
        },
        actions: [
          action("start", "Start auto workflow", "ooo auto <goal>", "Enter"),
          action("verify", "Run checks", "/verify", "v")
        ]
      }
    ]
  end

  defp agent_title(_id, pane) do
    text_value(pane, :agent) || text_value(pane, :name) || text_value(pane, :title) ||
      fallback_agent_title(pane)
  end

  defp fallback_agent_title(pane) do
    status = text_value(pane, :status) || text_value(pane, :state) || "active"
    task = text_value(pane, :task) || ""

    cond do
      String.contains?(String.downcase(task), "ooo auto") ->
        "Auto run"

      String.contains?(String.downcase(task), "ooo interview") ->
        "Interview"

      String.contains?(String.downcase(task), "ooo pm") ->
        "PM interview"

      String.contains?(String.downcase(status), "fail") ->
        "Attention needed"

      String.contains?(String.downcase(status), "cancel") ->
        "Stopped work"

      String.contains?(String.downcase(status), "queued") ->
        "Queued work"

      true ->
        "Active work"
    end
  end

  defp agent_workspace_status(0), do: "ready · 0 active"
  defp agent_workspace_status(count), do: "running · #{count} active"

  defp agent_workspace_actions(0) do
    [
      action("new_pm", "Start PM interview", "ooo pm <goal>", "o"),
      action("new_interview", "Start interview", "ooo interview <goal>", "i"),
      action("new_auto", "Start auto workflow", "ooo auto <goal>", "a"),
      action("sessions", "Inspect sessions", "/sessions", "s")
    ]
  end

  defp agent_workspace_actions(_count) do
    [
      action("answer", "Answer", "/answer <text>", "Enter"),
      action("sessions", "Inspect sessions", "/sessions", "s"),
      action("cancel", "Cancel active work", "/cancel", "x"),
      action("verify", "Run verifier", "/verify", "v")
    ]
  end

  defp agent_workspace_next(0),
    do: "Choose ooo pm <goal>, ooo interview <goal>, or ooo auto <goal>."

  defp agent_workspace_next(_count),
    do: "Use Enter to focus active work, /sessions to inspect history."

  defp agent_lane_group(status) do
    status = status |> to_string() |> String.downcase()

    cond do
      String.contains?(status, "cancel") or String.contains?(status, "complete") ->
        "agent:stopped"

      String.contains?(status, "fail") or String.contains?(status, "error") ->
        "agent:attention"

      true ->
        "agent:active"
    end
  end

  defp agent_phase(status) do
    status = status |> to_string() |> String.downcase()

    cond do
      String.contains?(status, "queued") -> "queued"
      String.contains?(status, "preparing") -> "preparing"
      String.contains?(status, "pause") -> "paused"
      String.contains?(status, "cancel") -> "cancelled"
      String.contains?(status, "complete") -> "completed"
      String.contains?(status, "fail") or String.contains?(status, "error") -> "needs attention"
      String.contains?(status, "running") -> "updating"
      true -> "active"
    end
  end

  defp agent_progress(status, pane) do
    status = status |> to_string() |> String.downcase()
    explicit = value(pane, :progress)
    event_count = text_value(pane, :event_count) || text_value(pane, :events)

    cond do
      is_list(explicit) ->
        explicit
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(String.trim(&1) == ""))

      is_binary(explicit) ->
        [explicit]

      String.contains?(status, "running") and is_binary(event_count) ->
        ["#{event_count} events", "updates connected"]

      String.contains?(status, "queued") ->
        ["queued", "waiting for first event"]

      String.contains?(status, "pause") ->
        ["paused", "resume available"]

      String.contains?(status, "cancel") ->
        ["cancel requested", "cleanup recorded"]

      String.contains?(status, "complete") ->
        ["finished", "ready to inspect"]

      String.contains?(status, "fail") or String.contains?(status, "error") ->
        ["error captured", "inspect before retry"]

      is_binary(event_count) ->
        ["#{event_count} events", "updates connected"]

      true ->
        ["work open", "updates connected"]
    end
  end

  defp agent_controls(status) do
    status = status |> to_string() |> String.downcase()

    cond do
      String.contains?(status, "queued") ->
        ["focus", "cancel", "inspect"]

      String.contains?(status, "preparing") ->
        ["focus", "cancel", "inspect"]

      String.contains?(status, "pause") ->
        ["focus", "resume", "cancel"]

      String.contains?(status, "cancel") ->
        ["inspect", "resume session", "clear"]

      String.contains?(status, "complete") ->
        ["inspect", "resume session", "verify"]

      String.contains?(status, "fail") or String.contains?(status, "error") ->
        ["inspect error", "retry", "cancel"]

      true ->
        ["focus", "pause", "cancel", "resume"]
    end
  end

  defp agent_activity(status, pane) do
    [
      activity_status(status),
      focused_activity(pane),
      parent_activity(text_value(pane, :parent_call_id)),
      runtime_activity(text_value(pane, :runtime_events)),
      evidence_part("exit", text_value(pane, :exit_code)),
      event_activity(text_value(pane, :event_count) || text_value(pane, :events))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp focused_activity(pane) do
    if value(value(pane, :pane_state, %{}), :focused?, false) == true or
         value(pane, :focused?, false) == true do
      "focused in workspace"
    else
      nil
    end
  end

  defp activity_status(status), do: "work #{status}"
  defp parent_activity(nil), do: nil
  defp parent_activity(""), do: nil
  defp parent_activity(_parent), do: "parent session linked"
  defp event_activity(nil), do: nil
  defp event_activity(""), do: nil
  defp event_activity(count), do: "#{count} updates received"

  defp runtime_activity(nil), do: nil
  defp runtime_activity(""), do: nil

  defp runtime_activity(events) do
    events
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&runtime_event_label/1)
    |> Enum.uniq()
    |> Enum.join(", ")
    |> case do
      "" -> nil
      labels -> "runtime #{labels}"
    end
  end

  defp runtime_event_label("stream_started"), do: "updates connected"
  defp runtime_event_label("stream_event"), do: "output received"
  defp runtime_event_label("cancelled"), do: "cancel acknowledged"
  defp runtime_event_label("failed"), do: "error captured"
  defp runtime_event_label("completed"), do: "completed"
  defp runtime_event_label("paused"), do: "paused"
  defp runtime_event_label("resumed"), do: "resumed"
  defp runtime_event_label(_event), do: "updated"

  defp user_current(nil), do: nil

  defp user_current(current) do
    current
    |> to_string()
    |> String.replace_prefix("stream: ", "")
    |> String.replace("workflow", "work")
  end

  defp agent_health(status) do
    status = status |> to_string() |> String.downcase()

    cond do
      String.contains?(status, "fail") or String.contains?(status, "error") -> "needs attention"
      String.contains?(status, "cancel") -> "stopped"
      String.contains?(status, "queued") -> "queued"
      String.contains?(status, "pause") -> "paused"
      String.contains?(status, "complete") -> "done"
      true -> "live"
    end
  end

  defp sessions_workspace(state, _command_result) do
    sessions = ResumeSessions.list(state, 3)

    records =
      Enum.with_index(sessions, 1)
      |> Enum.map(fn {session, index} -> session_record(session, index) end)

    %{
      kind: "sessions",
      title: "Sessions",
      status: if(records == [], do: "empty", else: "resumable"),
      selected: selected_id(records),
      records: records,
      detail: selected_detail(records, "No resumable sessions yet."),
      actions: [
        action("start", "Start PM interview", "ooo pm <goal>", "o"),
        action("resume_latest", "Resume latest", "/resume latest", "l"),
        action("resume_selected", "Resume selected", "/resume 1", "Enter")
      ],
      shortcuts: workspace_shortcuts("Enter resume"),
      next:
        if(records == [],
          do: "Start with ooo pm <goal>.",
          else: "Resume a numbered workspace or start new work."
        )
    }
  end

  defp resume_workspace(state, command_result) do
    sessions = Map.get(command_result, :sessions) || ResumeSessions.list(state)

    records =
      Enum.with_index(sessions, 1)
      |> Enum.map(fn {session, index} -> session_record(session, index) end)

    %{
      kind: "resume",
      title: "Resume",
      status: if(records == [], do: "empty", else: "resumable"),
      selected: selected_id(records),
      records: records,
      detail: selected_detail(records, "No resumable sessions yet."),
      actions: [
        action("resume_latest", "Resume latest", "/resume latest", "l"),
        action("resume_selected", "Resume selected", "/resume 1", "Enter"),
        action("show_all", "Show all sessions", "/resume --all", "a")
      ],
      shortcuts: workspace_shortcuts("Enter resume"),
      next:
        if(records == [],
          do: "No journaled sessions found.",
          else: "Choose a numbered workspace to resume."
        )
    }
  end

  defp plugin_area(state) do
    state
    |> value(:startup_result, state)
    |> PluginStatusArea.render()
  end

  defp mcp_workspace_actions([]) do
    [
      action("plugins", "Inspect plugins", "/plugins", "p"),
      action("verify", "Verify connections", "/verify", "v")
    ]
  end

  defp mcp_workspace_actions(_topology_records) do
    [
      action("sessions", "Show child panes", "/sessions", "s"),
      action("agents", "Focus guided work", "/agents", "a"),
      action("verify", "Verify connections", "/verify", "v")
    ]
  end

  defp mcp_tool_records(state) do
    state
    |> command_registry()
    |> case do
      {:ok, registry} ->
        registry
        |> CommandRegistry.entries()
        |> Enum.filter(&mcp_tool_entry?/1)
        |> Enum.map(&mcp_tool_record/1)

      :error ->
        []
    end
  end

  defp mcp_topology_records(state) do
    topology = value(state, :mcp_topology, %{})
    nodes = value(topology, :nodes, %{})
    edges = value(topology, :edges, %{})

    nodes
    |> Map.values()
    |> Enum.filter(&(value(&1, :kind) == :parent_call))
    |> Enum.sort_by(&{value(&1, :latest_event_seq, 0), value(&1, :parent_call_id, "")}, :desc)
    |> Enum.map(&mcp_topology_record(&1, edges, state))
  end

  defp mcp_topology_record(parent, edges, state) do
    parent_call_id = text_value(parent, :parent_call_id) || "unknown-parent"
    parent_pane = mcp_parent_pane(parent_call_id, state)
    tool_name = mcp_parent_tool_name(parent_pane || parent)
    child_ids = topology_child_ids(parent_call_id, edges)
    status = parent_call_status(parent_call_id, state)
    child_summary = child_status_summary(child_ids, state)

    %{
      id: "mcp-live:" <> parent_call_id,
      title: "MCP toolcall " <> tool_name,
      state: status,
      health: "#{length(child_ids)} child #{plural(length(child_ids), "pane")}",
      fields: %{
        parent: parent_call_id,
        server: text_value(parent, :runtime_source) || "mcp",
        transport: text_value(parent, :transport) || "unknown",
        stream: "parent pane plus linked child panes",
        children: if(child_summary == "", do: "none linked yet", else: child_summary),
        latest: latest_sequence(parent)
      },
      actions: [
        action("sessions", "Show child panes", "/sessions", "s"),
        action("agents", "Focus guided work", "/agents", "a"),
        action("verify", "Verify connections", "/verify", "v")
      ]
    }
  end

  defp mcp_parent_pane(parent_call_id, state) do
    (list_at(state, [:parent, :working]) ++ list_at(state, [:parent, :completed]))
    |> Enum.find(&(text_value(&1, :parent_call_id) == parent_call_id))
  end

  defp mcp_parent_tool_name(source) when is_map(source) do
    params = value(source, :params, %{})
    text_value(params, :name) || text_value(source, :method) || "tools/call"
  end

  defp mcp_parent_tool_name(_source), do: "tools/call"

  defp topology_child_ids(parent_call_id, edges) when is_map(edges) do
    edges
    |> Map.values()
    |> Enum.filter(&(text_value(&1, :parent_call_id) == parent_call_id))
    |> Enum.map(&text_value(&1, :child_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp topology_child_ids(_parent_call_id, _edges), do: []

  defp parent_call_status(parent_call_id, state) do
    cond do
      parent_call_in?(state, [:parent, :working], parent_call_id) ->
        "streaming"

      parent_call_in?(state, [:parent, :completed], parent_call_id) ->
        "completed"

      true ->
        "linked"
    end
  end

  defp parent_call_in?(state, path, parent_call_id) do
    state
    |> get_in(path)
    |> List.wrap()
    |> Enum.any?(&(text_value(&1, :parent_call_id) == parent_call_id))
  end

  defp child_status_summary(child_ids, state) do
    child_ids
    |> Enum.map(fn child_id ->
      status = child_status(child_id, state)
      child_id <> " " <> status
    end)
    |> Enum.join(", ")
  end

  defp child_status(child_id, state) do
    cond do
      child_in?(state, [:child, :working], child_id) -> "streaming"
      child_in?(state, [:child, :completed], child_id) -> "completed"
      true -> "linked"
    end
  end

  defp child_in?(state, path, child_id) do
    state
    |> list_at(path)
    |> Enum.any?(&(text_value(&1, :child_id) == child_id))
  end

  defp list_at(map, path) when is_map(map) and is_list(path) do
    case get_in(map, path) do
      list when is_list(list) -> list
      _value -> []
    end
  end

  defp list_at(_map, _path), do: []

  defp latest_sequence(parent) do
    case value(parent, :latest_event_seq) do
      nil -> "waiting for first event"
      seq -> "event " <> to_string(seq)
    end
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp command_registry(state) do
    cond do
      is_map(get_in(state, [:startup_result, :commands])) ->
        {:ok, get_in(state, [:startup_result, :commands])}

      is_map(get_in(state, [:startup_result, :runtime, :commands])) ->
        {:ok, get_in(state, [:startup_result, :runtime, :commands])}

      is_map(get_in(state, [:runtime, :commands])) ->
        {:ok, get_in(state, [:runtime, :commands])}

      true ->
        :error
    end
  end

  defp mcp_tool_entry?(entry) when is_map(entry) do
    Map.get(entry, :source) == :mcp or
      get_in(entry, [:run_spec, :kind]) == :mcp_tool or
      (Map.get(entry, :source) == :dynamic_skill and
         not is_nil(get_in(entry, [:metadata, :mcp_tool])))
  end

  defp mcp_tool_entry?(_entry), do: false

  defp mcp_tool_record(entry) do
    schema = get_in(entry, [:metadata, :input_schema]) || %{}
    args = Map.get(entry, :args, [])

    tool_name =
      get_in(entry, [:metadata, :tool_name]) || get_in(entry, [:metadata, :mcp_tool]) ||
        get_in(entry, [:run_spec, :mcp_tool]) || entry.name

    server_id = get_in(entry, [:metadata, :server_id]) || Map.get(entry, :source_id, "mcp")

    %{
      id: "mcp-tool:" <> to_string(server_id) <> ":" <> to_string(tool_name),
      title: to_string(tool_name),
      state: "schema",
      health: if(args == [] and schema == %{}, do: "no args", else: "#{length(args)} args"),
      fields: %{
        server: server_id,
        command: Map.get(entry, :slash),
        transport:
          get_in(entry, [:metadata, :transport]) || get_in(entry, [:run_spec, :transport]),
        schema: schema_summary(schema, args)
      },
      actions: [
        action("invoke", "Invoke tool", Map.get(entry, :slash), "Enter"),
        action("verify", "Test connection", "/verify", "v")
      ]
    }
  end

  defp schema_summary(schema, args) do
    required =
      schema
      |> case do
        schema when is_map(schema) -> Map.get(schema, "required", Map.get(schema, :required, []))
        _schema -> []
      end
      |> List.wrap()
      |> Enum.map(&to_string/1)

    arg_names =
      args
      |> Enum.map(fn arg -> value(arg, :name, "") end)
      |> Enum.reject(&(&1 == ""))

    cond do
      arg_names != [] and required != [] ->
        "args " <> Enum.join(arg_names, ", ") <> "; required " <> Enum.join(required, ", ")

      arg_names != [] ->
        "args " <> Enum.join(arg_names, ", ")

      required != [] ->
        "required " <> Enum.join(required, ", ")

      true ->
        "no input schema"
    end
  end

  defp plugin_record(item, type) do
    %{
      id: type <> ":" <> item.plugin_id,
      title: plugin_display_title(item),
      state: item.state_label,
      health: plugin_health(item),
      fields: %{
        role: plugin_role(type),
        setup: plugin_setup(item),
        capabilities: ["commands", "skills", "guided work"]
      },
      actions: [
        action("inspect", "Inspect", "/plugins", "i"),
        action("reload", "Reload", "/reload", "r"),
        action("verify", "Test", "/verify", "v")
      ]
    }
  end

  defp plugin_role("plugin"), do: "guided work"
  defp plugin_role("config"), do: "project workflow setup"
  defp plugin_role(type), do: type

  defp plugin_setup(%{source_type: "official"}), do: "built in"
  defp plugin_setup(_item), do: "project extension"

  defp plugin_display_title(item) do
    item
    |> value(:display_name, value(item, :plugin_id, "Plugin"))
    |> to_string()
    |> case do
      "Ouroboros workflows" -> "Guided workflows"
      "Guided workflow tools" -> "Guided workflows"
      title -> title
    end
  end

  defp control_record(id, title, state, facts, command) do
    %{
      id: "control:" <> id,
      title: title,
      state: state,
      health: "ready",
      fields: %{rules: facts},
      actions: [action("inspect", "Inspect", command, "Enter")]
    }
  end

  defp session_record(session, index) do
    %{
      id: "session:" <> Integer.to_string(index),
      title: ResumeSessions.session_title(session),
      state: ResumeSessions.session_activity(session),
      health: "resumable",
      fields: %{updated: Map.get(session, :updated_label, "unknown")},
      actions: [
        action("resume", "Resume", "/resume #{index}", "Enter"),
        action("latest", "Resume latest", "/resume latest", "l")
      ]
    }
  end

  defp action(id, label, command, shortcut) do
    %{id: id, label: label, command: command, shortcut: shortcut, enabled: true}
  end

  defp workflow_start_record(:auto, line) do
    %{
      id: "workflow:auto",
      title: "Auto run",
      state: "preparing",
      health: "approval gated",
      fields: %{
        step: "approval plan",
        task: line,
        current: "interview -> seed -> execute -> verify",
        progress: ["starting now", "approval checkpoint before file changes"],
        target: "project workspace",
        controls: ["Enter focus", "/cancel", "/agents", "/verify"],
        activity: ["plan visible", "waiting for first update"]
      },
      actions: [
        action("focus", "Focus work", "/agents", "Enter"),
        action("cancel", "Cancel", "/cancel", "x"),
        action("verify", "Verify", "/verify", "v")
      ]
    }
  end

  defp workflow_start_record(:interview, line) do
    %{
      id: "workflow:interview",
      title: "Socratic interview",
      state: "asking",
      health: "live",
      fields: %{
        step: "first question",
        task: line,
        current: "clarify the requirement before planning",
        progress: ["question surface opening", "answer choices will appear here"],
        target: "main session",
        controls: ["type answer", "1-9 select", "/cancel"],
        activity: ["interview started"]
      },
      actions: [
        action("answer", "Answer", "/answer <text>", "Enter"),
        action("agents", "Inspect work", "/agents", "a"),
        action("cancel", "Cancel", "/cancel", "x")
      ]
    }
  end

  defp workflow_start_record(:pm, line) do
    %{
      id: "workflow:pm",
      title: "PM interview",
      state: "asking",
      health: "live",
      fields: %{
        step: "product discovery",
        task: line,
        current: "shape requirements with answer choices",
        progress: ["first question opening", "PM brief will build from answers"],
        target: "main session",
        controls: ["type answer", "1-9 select", "/cancel"],
        activity: ["PM interview started"]
      },
      actions: [
        action("answer", "Answer", "/answer <text>", "Enter"),
        action("agents", "Inspect work", "/agents", "a"),
        action("cancel", "Cancel", "/cancel", "x")
      ]
    }
  end

  defp workflow_start_record(:generic, line) do
    %{
      id: "workflow:guided",
      title: "Guided work",
      state: "preparing",
      health: "live",
      fields: %{
        step: "routing",
        task: line,
        current: "preparing guided work",
        progress: ["work accepted", "waiting for first update"],
        target: "main session",
        controls: ["Enter focus", "/cancel", "/agents"],
        activity: ["guided work started"]
      },
      actions: [
        action("focus", "Focus work", "/agents", "Enter"),
        action("cancel", "Cancel", "/cancel", "x")
      ]
    }
  end

  defp workflow_start_title(:auto), do: "Auto Run"
  defp workflow_start_title(:interview), do: "Socratic Interview"
  defp workflow_start_title(:pm), do: "PM Interview"
  defp workflow_start_title(:generic), do: "Guided Work"

  defp workflow_start_status(:auto), do: "approval plan starting"
  defp workflow_start_status(:interview), do: "question starting"
  defp workflow_start_status(:pm), do: "question starting"
  defp workflow_start_status(:generic), do: "starting"

  defp workflow_start_actions(:auto) do
    [
      action("focus", "Focus work", "/agents", "Enter"),
      action("cancel", "Cancel", "/cancel", "x"),
      action("verify", "Verify", "/verify", "v")
    ]
  end

  defp workflow_start_actions(_mode) do
    [
      action("answer", "Answer", "/answer <text>", "Enter"),
      action("agents", "Inspect work", "/agents", "a"),
      action("cancel", "Cancel", "/cancel", "x")
    ]
  end

  defp workflow_start_next(:auto),
    do: "Review the approval plan; execution waits before changing files."

  defp workflow_start_next(:interview), do: "Answer the first question to continue."
  defp workflow_start_next(:pm), do: "Answer the first PM question to continue."
  defp workflow_start_next(:generic), do: "Watch this workspace for the first prompt or result."

  defp workflow_mode(line) do
    normalized = line |> String.trim() |> String.downcase()

    cond do
      normalized == "ooo auto" or String.starts_with?(normalized, "ooo auto ") ->
        :auto

      normalized == "ooo interview" or String.starts_with?(normalized, "ooo interview ") ->
        :interview

      normalized == "ooo pm" or String.starts_with?(normalized, "ooo pm ") ->
        :pm

      true ->
        :generic
    end
  end

  defp workspace_shortcuts(primary) do
    ["Up/Dn rows", primary, "type to compose"]
  end

  defp selected_id([%{id: id} | _rest]), do: id
  defp selected_id(_records), do: nil

  defp selected_detail([record | _rest], _empty), do: record
  defp selected_detail(_records, empty), do: %{title: empty, state: "empty", actions: []}

  defp plugin_health(%{state_label: state}) when state in ["loaded", "enabled", "ready to load"],
    do: "ready"

  defp plugin_health(%{state_label: "disabled"}), do: "disabled"
  defp plugin_health(_item), do: "needs attention"

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_map, _key, default), do: default

  defp text_value(map, key) do
    case value(map, key, nil) do
      nil -> nil
      "" -> nil
      value -> to_string(value)
    end
  end

  defp list_value(map, key) do
    case value(map, key, nil) do
      value when is_list(value) ->
        value
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(String.trim(&1) == ""))

      _other ->
        nil
    end
  end
end
