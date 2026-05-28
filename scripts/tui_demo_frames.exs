alias Ourocode.Terminal.Tui
alias Ourocode.Terminal.WorkspaceModel

base_frame = """
+-- ourocode terminal region=header_status x=0 y=0 w=88 h=5
| app=ourocode status=healthy runtime=ready session=demo
| project=/Users/dev/Project/ourocode
| cwd=/Users/dev/Project/ourocode
+--
+-- Parent/Child Sessions region=runtime_panes layout=terminal_split
| [parent-region] x=0 y=0 w=80 h=8
| parent empty
| [child-region] x=0 y=9 w=80 h=12
| child empty
+--
+-- Plugin Status (1) region=plugin_status x=0 y=18 w=80 h=4
| status=ready visible=1
| [BUILT-IN] Ouroboros workflows - Official plugin - loaded
+--
+-- State
| surface=terminal focus=task_prompt layout=compact
| runtime=ready stream=streaming journal=ready
| queued=0 replayable?=true connections=ready
| hooks=idle events=0
+--
"""

frame = fn prompt, activity, opts ->
  opts =
    opts
    |> Map.put_new(:auth, {"model: codex cli", :ok})

  base_frame
  |> Tui.frame_lines(activity, prompt, 100, 24, opts)
  |> Enum.join("\n")
end

pm_picker =
  frame.(
    "",
    ["you> ooo pm design plugin onboarding", "task: first picker ready"],
    %{
      interview_block:
        {"INTERVIEW",
         [
           "Round 1  ·  PM interview",
           "What outcome should this PM interview produce?",
           ">> [1] Define the target user - anchor the PM brief around the primary audience",
           "   [2] Define the activation outcome - focus on the proof moment",
           "   [3] Audit the existing flow - start from the current path"
         ], "Choose an option or type a custom answer"},
      wonder_focus: true
    }
  )

accepted =
  frame.(
    "",
    ["you> ooo pm design plugin onboarding", "task: answer accepted"],
    %{
      interview_block:
        {"INTERVIEW",
         [
           {"Round accepted", :strong},
           {"Question  What outcome should this PM interview produce?", :warn},
           {"Answer    Define the target user", :strong},
           {"Next      answer sent; generating choices", :dim},
           :rule,
           {"■■⬝ building next answer choices (~6s) - no input needed; Esc pauses", :dim},
           {"No input needed; choices will appear automatically", :dim}
         ], "type your answer + Enter   Esc pause"}
    }
  )

agents_workspace = %{
  kind: "agents",
  title: "Agents",
  status: "running",
  selected: "agent:pm",
  records: [
    %{
      id: "agent:pm",
      title: "PM interview",
      state: "waiting",
      health: "live",
      fields: %{phase: "generating answer choices", progress: "answer accepted"}
    },
    %{
      id: "agent:verify",
      title: "Health checks",
      state: "ready",
      health: "ready",
      fields: %{phase: "ready", progress: "17 checks passed"}
    }
  ],
  detail: %{
    id: "agent:pm",
    title: "PM interview",
    state: "waiting",
    fields: %{
      phase: "generating answer choices",
      progress: "answer accepted",
      controls: "Esc pause, /cancel, /sessions"
    }
  },
  actions: [],
  shortcuts: ["Up/Dn rows", "Enter row action", "type to compose"],
  next: "Watch active work or type a new command."
}

frames = [
  %{title: "Start", duration_ms: 950, text: frame.("", [], %{})},
  %{title: "Open guided work", duration_ms: 850, text: frame.("ooo", [], %{})},
  %{
    title: "Type a goal",
    duration_ms: 750,
    text: frame.("ooo pm design plugin onboarding", [], %{})
  },
  %{title: "Answer the interview", duration_ms: 1_450, text: pm_picker},
  %{title: "Continue safely", duration_ms: 1_200, text: accepted},
  %{
    title: "Track active work",
    duration_ms: 1_250,
    text: frame.("", [], %{workspace: agents_workspace})
  },
  %{
    title: "Auto is approval-gated",
    duration_ms: 1_350,
    text:
      frame.("", [], %{workspace: WorkspaceModel.workflow_start("ooo auto improve onboarding")})
  }
]

IO.write(Ourocode.Json.encode!(frames))
