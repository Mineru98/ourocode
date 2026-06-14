defmodule Ourocode.Model.CatalogTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Model.Catalog

  defp which(installed) do
    fn bin -> if bin in installed, do: "/usr/bin/#{bin}", else: nil end
  end

  test "lists direct-API providers first and excludes slow agent CLI backends" do
    models =
      Catalog.list(
        codex_signed_in: false,
        anthropic_signed_in: false,
        which: which(["claude", "codex", "gemini"])
      )

    assert [%{id: :codex}, %{id: :claude_api} | _] = models
    ids = Enum.map(models, & &1.id)
    assert :codex in ids
    assert :claude_api in ids
    assert :gemini in ids

    gemini = Catalog.fetch(models, :gemini)
    assert gemini.status == :ready
  end

  test "claude_api status reflects Anthropic sign-in and stays selectable" do
    out =
      Catalog.fetch(
        Catalog.list(codex_signed_in: false, anthropic_signed_in: false, which: which([])),
        :claude_api
      )

    assert out.status == {:needs_auth, "/login-claude"}
    assert Model.needs_auth?(out)

    inn =
      Catalog.fetch(
        Catalog.list(codex_signed_in: false, anthropic_signed_in: true, which: which([])),
        :claude_api
      )

    assert inn.status == :ready
    assert Model.ready?(inn)
  end

  test "default never falls back to the Claude CLI" do
    assert Catalog.default(
             codex_signed_in: false,
             anthropic_signed_in: true,
             which: which(["claude"]),
             ouroboros_backend: "claude"
           ).id == :claude_api

    # Not signed in to the subscription: stay on direct Claude so the UI can
    # show /login-claude instead of spawning the slow CLI.
    assert Catalog.default(
             codex_signed_in: false,
             anthropic_signed_in: false,
             which: which(["claude"]),
             ouroboros_backend: "claude"
           ).id == :claude_api
  end

  test "codex status reflects sign-in state and stays selectable" do
    out = Catalog.fetch(Catalog.list(codex_signed_in: false, which: which([])), :codex)
    assert out.status == {:needs_auth, "/login"}
    assert Model.needs_auth?(out)

    inn = Catalog.fetch(Catalog.list(codex_signed_in: true, which: which([])), :codex)
    assert inn.status == :ready
    assert Model.ready?(inn)
  end

  test "default can use remaining non-agent CLIs, else falls back to codex" do
    with_cli =
      Catalog.default(
        codex_signed_in: false,
        anthropic_signed_in: false,
        which: which(["gemini"]),
        ouroboros_config_path: nil
      )

    assert with_cli.id == :gemini

    no_cli =
      Catalog.default(
        codex_signed_in: false,
        anthropic_signed_in: false,
        which: which([]),
        ouroboros_config_path: nil
      )

    assert no_cli.id == :codex

    signed =
      Catalog.default(
        codex_signed_in: true,
        anthropic_signed_in: false,
        which: which(["gemini"]),
        ouroboros_config_path: nil
      )

    assert signed.id == :codex
  end

  test "default follows the configured Ouroboros backend before installed CLI order" do
    assert Catalog.default(
             codex_signed_in: false,
             which: which(["claude", "codex"]),
             ouroboros_backend: "codex"
           ).id == :codex

    assert Catalog.default(
             codex_signed_in: true,
             which: which(["claude", "codex"]),
             ouroboros_backend: "codex"
           ).id == :codex

    assert Catalog.default(
             codex_signed_in: false,
             which: which(["claude"]),
             ouroboros_backend: "codex"
           ).id == :codex

    assert Catalog.default(
             codex_signed_in: true,
             which: which(["claude", "codex"]),
             ouroboros_backend: "claude"
           ).id == :claude_api
  end

  test "default reads Ouroboros config.yaml backend as a read-only preference" do
    dir = Path.join(System.tmp_dir!(), "ourocode-catalog-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    path = Path.join(dir, "config.yaml")

    File.write!(path, """
    economics:
      tiers:
        frugal:
          intelligence_range:
          - 9
          - 11
    llm:
      backend: claude
    orchestrator:
      runtime_backend: codex
    """)

    assert Catalog.default(
             codex_signed_in: false,
             which: which(["claude", "codex"]),
             ouroboros_config_path: path
           ).id == :codex
  end

  test "selectable hides unavailable backends" do
    models = Catalog.list(codex_signed_in: false, which: which([]))
    sel = Catalog.selectable(models)

    assert Enum.any?(sel, &(&1.id == :codex))
    refute Enum.any?(sel, &(&1.status == :unavailable))
  end

  test "cli runner replays conversation history into the one-shot prompt" do
    alias Ourocode.Model.Conversation

    dir =
      Path.join(System.tmp_dir!(), "ourocode-catalog-cli-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)

    # Echoes its prompt argument back, standing in for `gemini -p <prompt>`.
    script = Path.join(dir, "gemini")
    File.write!(script, "#!/bin/sh\nprintf '%s' \"$2\"\n")
    File.chmod!(script, 0o755)

    which = fn bin -> if bin == "gemini", do: script, else: nil end
    gemini = Catalog.fetch(Catalog.list(codex_signed_in: false, which: which), :gemini)

    conversation = Conversation.add_turn(Conversation.new(), "first question", "first answer")

    assert {:ok, echoed} =
             Model.stream(gemini, "follow-up", [history: conversation], fn _chunk -> :ok end)

    assert echoed =~ "user: first question\nassistant: first answer"
    assert echoed =~ "## Current message\nfollow-up"

    # An empty conversation leaves the first turn byte-identical.
    assert {:ok, "plain"} =
             Model.stream(gemini, "plain", [history: Conversation.new()], fn _chunk -> :ok end)
  end

  test "stream dispatches through the model's runner" do
    model = %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn prompt, _opts, on_chunk ->
        on_chunk.("[" <> prompt <> "]")
        {:ok, "[" <> prompt <> "]"}
      end
    }

    parent = self()
    assert {:ok, "[hi]"} = Model.stream(model, "hi", [], fn c -> send(parent, {:c, c}) end)
    assert_received {:c, "[hi]"}
  end
end
