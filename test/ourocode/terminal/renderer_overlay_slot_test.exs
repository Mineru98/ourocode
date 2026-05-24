defmodule Ourocode.Terminal.RendererOverlaySlotTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.RendererOverlaySlot

  test "build keeps modal overlays ahead of suggestions" do
    assert {:palette, %{entries: []}} =
             RendererOverlaySlot.build("@mcp:read", :normal, %{
               palette: %{entries: []},
               resource_mentions: [{"read://one", "Read one"}],
               key_help: true
             })

    assert {:model, %{models: []}} =
             RendererOverlaySlot.build("@mcp:read", :normal, %{
               model: %{models: []},
               resource_mentions: [{"read://one", "Read one"}]
             })
  end

  test "build orders resource, file, ooo, then key help overlays" do
    assert {:resource_mentions, [{"read://one", "Read one"}], 0} =
             RendererOverlaySlot.build("@mcp:read", :normal, %{
               resource_mentions: [{"read://one", "Read one"}],
               file_mentions: [{"lib/a.ex", "lib"}],
               key_help: true
             })

    assert {:file_mentions, [{"lib/a.ex", "lib"}], 0} =
             RendererOverlaySlot.build("@", :normal, %{
               file_mentions: [{"lib/a.ex", "lib"}],
               key_help: true
             })

    assert {:ooo_suggestions, [{"ooo run", "execute"}], 0} =
             RendererOverlaySlot.build("ooo", :normal, %{
               ooo_commands: [{"ooo run", "execute"}],
               key_help: true
             })

    assert {:key_help, :normal, %{key_help: true}} =
             RendererOverlaySlot.build("", :normal, %{key_help: true})
  end

  test "build clamps mention selection index" do
    assert {:file_mentions, _mentions, 1} =
             RendererOverlaySlot.build("@", :normal, %{
               pidx: 99,
               file_mentions: [{"lib/a.ex", "lib"}, {"lib/b.ex", "lib"}]
             })
  end

  test "build suppresses prompt suggestions outside normal non-wonder input" do
    opts = %{
      resource_mentions: [{"read://one", "Read one"}],
      ooo_commands: [{"ooo run", "execute"}],
      key_help: false
    }

    assert :none = RendererOverlaySlot.build("@mcp:read", :palette, opts)
    assert :none = RendererOverlaySlot.build("ooo", :normal, Map.put(opts, :wonder_focus, true))
  end
end
