defmodule Ourocode.Model.CatalogTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Model.Catalog

  defp which(installed) do
    fn bin -> if bin in installed, do: "/usr/bin/#{bin}", else: nil end
  end

  test "lists codex first, then only installed CLI backends" do
    models =
      Catalog.list(codex_signed_in: false, which: which(["claude"]))

    assert hd(models).id == :codex
    ids = Enum.map(models, & &1.id)
    assert :codex in ids
    assert :claude in ids
    assert :codex_cli in ids
    assert :gemini in ids

    claude = Catalog.fetch(models, :claude)
    gemini = Catalog.fetch(models, :gemini)
    assert claude.status == :ready
    assert gemini.status == :unavailable
  end

  test "codex status reflects sign-in state and stays selectable" do
    out = Catalog.fetch(Catalog.list(codex_signed_in: false, which: which([])), :codex)
    assert out.status == {:needs_auth, "/login"}
    assert Model.needs_auth?(out)

    inn = Catalog.fetch(Catalog.list(codex_signed_in: true, which: which([])), :codex)
    assert inn.status == :ready
    assert Model.ready?(inn)
  end

  test "default prefers a ready CLI, else falls back to codex" do
    with_cli = Catalog.default(codex_signed_in: false, which: which(["claude"]))
    assert with_cli.id == :claude

    no_cli = Catalog.default(codex_signed_in: false, which: which([]))
    assert no_cli.id == :codex

    signed = Catalog.default(codex_signed_in: true, which: which(["claude"]))
    assert signed.id == :codex
  end

  test "selectable hides unavailable backends" do
    models = Catalog.list(codex_signed_in: false, which: which([]))
    sel = Catalog.selectable(models)

    assert Enum.any?(sel, &(&1.id == :codex))
    refute Enum.any?(sel, &(&1.status == :unavailable))
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
