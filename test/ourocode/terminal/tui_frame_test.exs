defmodule Ourocode.Terminal.TuiFrameTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{Palette, Tui}

  @ssot_frame """
  +-- ourocode terminal region=header_status x=0 y=0 w=88 h=5
  | app=ourocode status=healthy runtime=ready session=terminal-1
  | project=/Users/dev/Project/ourocode
  | cwd=/Users/dev/Project/ourocode
  +--
  +-- Parent/Child Sessions region=runtime_panes layout=terminal_split
  | [parent-region] x=0 y=0 w=80 h=8
  | parent empty
  | [child-region] x=0 y=9 w=80 h=12
  | child empty
  +--
  +-- Plugin Status (0) region=plugin_status x=0 y=18 w=80 h=4
  | status=ready visible=0
  | empty
  +--
  +-- State
  | surface=terminal focus=task_prompt layout=compact
  | runtime=ready stream=streaming journal=ready
  | queued=0 replayable?=false transports=stdio,sse,streamable_http
  | hooks=idle events=0
  +--
  """

  defp render(prompt_buffer, activity \\ [], opts \\ %{}, cols \\ 100, rows \\ 24) do
    Tui.frame_lines(@ssot_frame, activity, prompt_buffer, cols, rows, opts)
  end

  test "no machine debug noise leaks from the SSoT projection" do
    text = render("") |> Enum.join("\n")

    refute text =~ "region="
    refute text =~ "+--"
    refute text =~ "status=healthy"
    refute text =~ "x=0 y=0"
  end

  test "transcript-first empty state is brand-forward and calm" do
    lines = render("")
    text = Enum.join(lines, "\n")

    assert Enum.any?(lines, &String.contains?(&1, "ourocode"))
    assert text =~ "Choose one starting mode"
    assert text =~ "ooo pm <goal>"
    assert text =~ "ooo interview <goal>"
    assert text =~ "ooo auto <goal>"
    assert text =~ "/ for commands"
    refute text =~ "/preflight"
    refute text =~ "/sessions"
    refute text =~ "Work state"
    refute text =~ "Useful commands"
    refute text =~ "Nothing here yet"
    refute text =~ "SESSIONS"
    refute text =~ "baseline"
  end

  test "status bar uses conditional density and mode-aware hints" do
    normal = render("", [], %{}, 120) |> Enum.join("\n")
    assert normal =~ "ready"
    assert normal =~ ""
    assert normal =~ "/ commands"
    assert normal =~ "ooo work"
    assert normal =~ "^C"
    # zeros and idle are hidden, not spelled out
    refute normal =~ "sessions 0"
    refute normal =~ "hooks idle"
    refute normal =~ "q0"

    palette =
      render("/", [], %{mode: :palette, palette: %{entries: Palette.entries(), index: 0}})
      |> Enum.join("\n")

    assert palette =~ "Enter run"
    assert palette =~ "Esc"
  end

  test "status bar can surface queued notifications" do
    text =
      render("", [], %{notifications: ["Esc again to clear input"]})
      |> Enum.join("\n")

    assert text =~ "Esc again to clear input"
  end

  test "live turn activity appears after a submitted guided command" do
    text =
      render("", ["task: starting"], %{
        live_turn_activity: [
          "live: PM interview is opening",
          "  activity: ■■⬝ waiting for the first visible update",
          "  pulse: watching for first question"
        ]
      })
      |> Enum.join("\n")

    assert text =~ "task: starting"
    assert text =~ "live: PM interview is opening"
    assert text =~ "activity: ■■⬝ waiting for the first visible update"
    assert text =~ "pulse: watching for first question"
    assert text =~ "■⬝⬝"
    assert text =~ "Queue a follow-up; Esc interrupts"
  end

  test "command palette shows selected command details without internal metadata" do
    text =
      render("/", [], %{mode: :palette, palette: %{entries: Palette.entries(), index: 0}})
      |> Enum.join("\n")

    assert text =~ "● /ooo pm"
    assert text =~ "Guided work"
    assert text =~ "Read-only"
    assert text =~ "Usage · ooo pm · goal required"
    refute text =~ "source="
    refute text =~ "trust="
    refute text =~ "capability kernel"
  end

  test "typed prompt replaces the composer placeholder" do
    text = render("ooo interview summarize this") |> Enum.join("\n")
    assert text =~ "> "
    assert text =~ "ooo interview"
    refute text =~ "Send a message"
  end

  test "ooo prompt opens a lightweight command suggestion overlay" do
    text = render("ooo") |> Enum.join("\n")

    assert text =~ "ooo structured work"
    assert text =~ "ooo pm"
    assert text =~ "ooo interview"
    assert text =~ "ooo auto"
    refute text =~ "ooo seed"
    refute text =~ "ooo ralph"
  end

  test "ooo prompt filters command suggestions by the next token" do
    text = render("ooo int") |> Enum.join("\n")

    assert text =~ "ooo structured work"
    assert text =~ "ooo interview"
    refute text =~ "ooo seed"

    pm_text = render("ooo p") |> Enum.join("\n")
    assert pm_text =~ "ooo pm"
    refute pm_text =~ "ooo publish"

    starter_text = render("ooo ") |> Enum.join("\n")
    assert starter_text =~ "ooo pm"
    assert starter_text =~ "ooo interview"
    assert starter_text =~ "ooo auto"
    refute starter_text =~ "ooo seed"

    assert render("ooo eval") |> Enum.join("\n") =~ "ooo evaluate"
    assert render("ooo brown") |> Enum.join("\n") =~ "ooo brownfield"
  end

  test "ooo prompt suggestion highlight follows the navigation index" do
    text = render("ooo", [], %{pidx: 2}) |> Enum.join("\n")

    assert text =~ "> ooo auto"
    refute text =~ "> ooo interview"
  end

  test "file mention overlay shows repo path suggestions" do
    text =
      render("review @tui", [], %{
        file_mentions: [{"lib/ourocode/terminal/tui.ex", "lib/ourocode/terminal"}]
      })
      |> Enum.join("\n")

    assert text =~ "@ files"
    assert text =~ "@lib/ourocode/terminal/tui.ex"
    assert text =~ "lib/ourocode/terminal"
  end

  test "key help overlay shows active-mode shortcuts" do
    text = render("", [], %{key_help: true}) |> Enum.join("\n")

    assert text =~ "keys"
    assert text =~ "@"
    assert text =~ "file mentions"
    assert text =~ "Ctrl-A/E"
  end

  test "mcp resource mention overlay shows resource candidates" do
    text =
      render("inspect @mcp:seed", [], %{
        resource_mentions: [{"ouroboros://seed/current", "current Seed draft"}]
      })
      |> Enum.join("\n")

    assert text =~ "@ mcp resources"
    assert text =~ "@mcp:ouroboros://seed/current"
    assert text =~ "current Seed draft"
  end

  test "transcript renders turns as labelled, railed blocks newest at the bottom" do
    lines = render("", ["you> hello", "ourocode> hi there", "task: queued task_1"])
    text = Enum.join(lines, "\n")

    assert text =~ "Answer"
    assert text =~ "OUROCODE"
    assert text =~ "│ hello"
    assert text =~ "│ hi there"
    assert text =~ "task: queued task_1"
    refute text =~ "you> hello"
    refute text =~ "Sign in with"
  end

  test "workspace command output renders as a selected management panel" do
    activity = [
      "Plugins",
      "ready; 1 installed plugin",
      "Choose:",
      "  >> Guided workflows - loaded · ready",
      "Now:",
      "  role: guided work",
      "Commands: /mcp",
      "Use Up/Dn rows; Enter inspect; type to compose"
    ]

    text = render("", activity) |> Enum.join("\n")

    assert text =~ "Plugins"
    assert text =~ "Choose:"
    assert text =~ ">> Guided workflows - loaded · ready"
    assert text =~ "Now:"
    refute text =~ "row actions"
    assert text =~ "Commands: /mcp"
    refute text =~ "• Plugins"
    assert text =~ "• >> Guided workflows"
  end

  test "large workspace keeps header and actions visible" do
    records =
      Enum.map(1..10, fn index ->
        %{
          id: "record:#{index}",
          title: "Saved workspace #{index}",
          state: "resumable",
          actions: []
        }
      end)

    workspace = %{
      kind: "resume",
      title: "Resume",
      status: "resumable",
      selected: "record:1",
      records: records,
      detail: List.first(records),
      actions: [
        %{shortcut: "l", command: "/resume latest", id: "latest", enabled: true},
        %{shortcut: "Enter", command: "/resume 1", id: "resume", enabled: true}
      ],
      shortcuts: ["Up/Dn rows", "Enter resume", "type to compose"],
      next: "Choose a numbered workspace to resume."
    }

    text =
      render("", [], %{workspace: workspace})
      |> Enum.join("\n")

    assert text =~ "Resume"
    assert text =~ "resumable; 10 choices"
    assert text =~ ">> Saved workspace 1 - resumable"
    assert text =~ "5 more choices below"
    assert text =~ "Open /resume latest | /resume 1"
    assert text =~ "Use Up/Dn rows; Enter resume; type to compose"
    refute text =~ "Saved workspace 10"
  end

  test "active workspace state overrides stale captured activity" do
    first = %{id: "record:first", title: "First", state: "ready", actions: []}

    workspace = %{
      kind: "plugins",
      title: "Plugins",
      status: "ready",
      selected: "record:first",
      records: [first],
      detail: first,
      actions: [%{shortcut: "v", command: "/verify", id: "verify", enabled: true}],
      shortcuts: ["j/k move"],
      next: "Run /verify."
    }

    text =
      render("", ["stale log entry"], %{workspace: workspace})
      |> Enum.join("\n")

    assert text =~ "Plugins"
    assert text =~ ">> First - ready"
    assert text =~ "workspace focus"
    assert text =~ "Enter row action"
    refute text =~ "stale log entry"
  end

  test "workspace focus hint adapts in narrow terminals" do
    first = %{id: "record:first", title: "First", state: "ready", actions: []}

    workspace = %{
      kind: "plugins",
      title: "Plugins",
      status: "ready",
      selected: "record:first",
      records: [first],
      detail: first,
      actions: [],
      shortcuts: ["j/k move"],
      next: "Run /verify."
    }

    narrow =
      render("", [], %{workspace: workspace}, 60)
      |> Enum.join("\n")

    assert narrow =~ "workspace"
    assert narrow =~ "Up/Dn rows"
    assert narrow =~ "Enter action"
    refute narrow =~ "/ commands"
  end

  test "command palette cleanly owns the body over an active workspace" do
    first = %{id: "record:first", title: "First", state: "ready", actions: []}

    workspace = %{
      kind: "plugins",
      title: "Plugins",
      status: "ready",
      selected: "record:first",
      records: [first],
      detail: first,
      actions: [%{shortcut: "v", command: "/verify", id: "verify", enabled: true}],
      shortcuts: ["j/k move"],
      next: "Run /verify."
    }

    text =
      render("/co", [], %{
        mode: :palette,
        palette: %{entries: Palette.filter(Palette.entries(), "/co"), index: 0},
        workspace: workspace
      })
      |> Enum.join("\n")

    assert text =~ "commands  ("
    assert text =~ "/commands"
    assert text =~ "> /co"
    refute text =~ "Plugins"
    refute text =~ ">> First - ready"
    refute text =~ "Try /verify"
  end

  test "workspace view overrides a paused interview body" do
    first = %{id: "record:first", title: "First", state: "ready", actions: []}

    workspace = %{
      kind: "plugins",
      title: "Plugins",
      status: "ready",
      selected: "record:first",
      records: [first],
      detail: first,
      actions: [],
      shortcuts: ["j/k move"],
      next: "Run /verify."
    }

    text =
      render("", ["paused interview transcript"], %{
        workspace: workspace,
        mcp_activity: ["activity: state saved"],
        interview_reasoning: ["step paused - discussing"],
        interview_paused: true,
        interview_block:
          {"INTERVIEW (paused)",
           [
             "Which workflow should continue?",
             ">> [1] Keep the interview visible",
             "[Custom answer] type any text, then Enter"
           ], "/answer <text> resumes"}
      })
      |> Enum.join("\n")

    assert text =~ "Plugins"
    assert text =~ ">> First - ready"
    assert text =~ "workspace focus"
    refute text =~ "Which workflow should continue?"
    refute text =~ "Keep the interview visible"
    refute text =~ "paused interview transcript"
    refute text =~ "activity log"
    refute text =~ "step paused"
  end

  test "command palette overlay lists filtered registry entries" do
    entries = Palette.filter(Palette.entries(), "/st")

    text =
      render("/st", [], %{mode: :palette, palette: %{entries: entries, index: 0}})
      |> Enum.join("\n")

    assert text =~ "commands  ("
    assert text =~ "/status"
    refute text =~ "/help"
  end

  test "command palette owns body while active over an interview" do
    entries = Palette.filter(Palette.entries(), "/agents")

    text =
      render("/agents", ["you> previous answer"], %{
        mode: :palette,
        palette: %{entries: entries, index: 0},
        wonder_focus: true,
        interview_block:
          {"INTERVIEW",
           [
             "Question  Which onboarding moment matters?",
             ">> [1] Install plugin",
             "   [2] Validate tools"
           ], "type custom answer"}
      })
      |> Enum.join("\n")

    assert text =~ "commands  ("
    assert text =~ "/agents"
    refute text =~ "Which onboarding moment matters?"
    refute text =~ "Install plugin"
    refute text =~ "previous answer"
  end

  test "command palette owns body while active over a workspace" do
    workspace = %{
      kind: "agents",
      title: "Agents",
      status: "running",
      selected: "agent:active",
      records: [
        %{
          id: "agent:active",
          label: "Active interview",
          status: "running",
          fields: %{current: "long active interview question"}
        }
      ],
      detail: %{id: "agent:active", label: "Active interview", fields: %{current: "detail"}},
      actions: [],
      shortcuts: ["j/k move"],
      next: "Watch active work."
    }

    entries = Palette.filter(Palette.entries(), "/cancel")

    text =
      render("/cancel", ["stale workspace transcript"], %{
        mode: :palette,
        palette: %{entries: entries, index: 0},
        workspace: workspace
      })
      |> Enum.join("\n")

    assert text =~ "commands  (1)"
    assert text =~ "/cancel"
    refute text =~ "agents workspace"
    refute text =~ "Active interview"
    refute text =~ "stale workspace transcript"
  end

  test "paused interview slash commands do not open a competing overlay" do
    paused =
      render("/answer", [], %{
        mode: :palette,
        palette: %{entries: Palette.filter(Palette.entries(), "/answer"), index: 0},
        interview_paused: true
      })
      |> Enum.join("\n")

    assert paused =~ "> /answer"
    refute paused =~ "commands  (1)"
    refute paused =~ "Use while paused"

    paused_with_text =
      render("/answer proceed with the builder flow", [], %{
        mode: :palette,
        palette: %{
          entries: Palette.filter(Palette.entries(), "/answer proceed with the builder flow"),
          index: 0
        },
        interview_paused: true
      })
      |> Enum.join("\n")

    assert paused_with_text =~ "> /answer proceed with the builder flow"
    refute paused_with_text =~ "commands  (1)"
    refute paused_with_text =~ "Use while paused"

    normal =
      render("/answer", [], %{
        mode: :palette,
        palette: %{entries: Palette.filter(Palette.entries(), "/answer"), index: 0}
      })
      |> Enum.join("\n")

    refute normal =~ "Use while paused"
  end

  test "model overlay lists detected backends with status and header label" do
    models = [
      %Ourocode.Model{
        id: :codex,
        label: "codex  (ChatGPT)",
        kind: :oauth,
        status: {:needs_auth, "/login"},
        run: fn _, _, _ -> {:ok, ""} end
      },
      %Ourocode.Model{
        id: :claude_api,
        label: "claude  (Claude Pro/Max)",
        kind: :oauth,
        status: :ready,
        run: fn _, _, _ -> {:ok, ""} end
      }
    ]

    text =
      render("", [], %{
        mode: :model,
        model: %{models: models, index: 1},
        auth: {"model: claude  (Claude Pro/Max)", :ok}
      })
      |> Enum.join("\n")

    assert text =~ "models · Ouroboros role profiles"
    assert text =~ "Socratic Interview  claude"
    assert text =~ "Execute/Evolve  claude"
    assert text =~ "codex"
    assert text =~ "sign in /login"
    assert text =~ "claude"
    assert text =~ "ready"
    assert text =~ "model: claude  (Claude Pro/Max)"
  end

  test "login focal card centres the device code and url" do
    text =
      render("", [], %{login: %{code: "ABCD-1234", url: "https://auth.openai.com/codex/device"}})
      |> Enum.join("\n")

    assert text =~ "Connect ChatGPT"
    assert text =~ "ABCD-1234"
    assert text =~ "https://auth.openai.com/codex/device"
    assert text =~ "waiting for approval"
  end

  test "fits exactly the requested terminal height" do
    assert length(render("")) == 24
  end
end
