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
    assert text =~ "Sign in with  /login,  then ask anything"
    assert text =~ "or type  /  to browse commands"
    refute text =~ "Nothing here yet"
    refute text =~ "SESSIONS"
  end

  test "status bar uses conditional density and mode-aware hints" do
    normal = render("", [], %{}, 120) |> Enum.join("\n")
    assert normal =~ "ready"
    assert normal =~ "stdio sse http"
    assert normal =~ "/  commands"
    assert normal =~ "^C  exit"
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

  test "command palette shows selected command details and capability semantics" do
    text =
      render("/", [], %{mode: :palette, palette: %{entries: Palette.entries(), index: 0}})
      |> Enum.join("\n")

    assert text =~ "selected /help"
    assert text =~ "source=builtin"
    assert text =~ "trust=builtin"
    assert text =~ "category=discovery"
    assert text =~ "capability kernel/read_only/default"
    assert text =~ "aliases=/?"
  end

  test "typed prompt replaces the composer placeholder" do
    text = render("ooo interview로 정리해줘") |> Enum.join("\n")
    assert text =~ "> "
    assert text =~ "ooo interview"
    refute text =~ "Send a message"
  end

  test "ooo prompt opens a lightweight command suggestion overlay" do
    text = render("ooo") |> Enum.join("\n")

    assert text =~ "ooo commands"
    assert text =~ "ooo interview"
    assert text =~ "ooo seed"
    assert text =~ "ooo ralph"
  end

  test "ooo prompt filters command suggestions by the next token" do
    text = render("ooo int") |> Enum.join("\n")

    assert text =~ "ooo commands"
    assert text =~ "ooo interview"
    refute text =~ "ooo seed"

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

    assert text =~ "+- keys"
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
    lines = render("", ["you> hello", "ourocode> hi there", "queued task task_1"])
    text = Enum.join(lines, "\n")

    assert text =~ "YOU"
    assert text =~ "OUROCODE"
    assert text =~ "| hello"
    assert text =~ "| hi there"
    assert text =~ "queued task task_1"
    refute text =~ "you> hello"
    refute text =~ "Sign in with"
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

  test "paused interview palette exposes answer command only in that context" do
    paused =
      render("/answer", [], %{
        mode: :palette,
        palette: %{entries: Palette.filter(Palette.entries(), "/answer"), index: 0},
        interview_paused: true
      })
      |> Enum.join("\n")

    assert paused =~ "commands  (1)"
    assert paused =~ "/answer"
    assert paused =~ "Use while paused"

    paused_with_text =
      render("/answer 한글로 진행", [], %{
        mode: :palette,
        palette: %{entries: Palette.filter(Palette.entries(), "/answer 한글로 진행"), index: 0},
        interview_paused: true
      })
      |> Enum.join("\n")

    assert paused_with_text =~ "commands  (1)"
    assert paused_with_text =~ "/answer"
    assert paused_with_text =~ "/answer <answer>"

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
        id: :claude,
        label: "claude cli",
        kind: :cli,
        status: :ready,
        run: fn _, _, _ -> {:ok, ""} end
      }
    ]

    text =
      render("", [], %{
        mode: :model,
        model: %{models: models, index: 1},
        auth: {"model: claude cli", :ok}
      })
      |> Enum.join("\n")

    assert text =~ "+- model"
    assert text =~ "codex  (ChatGPT)"
    assert text =~ "sign in required"
    assert text =~ "claude cli"
    assert text =~ "ready"
    assert text =~ "model: claude cli"
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
