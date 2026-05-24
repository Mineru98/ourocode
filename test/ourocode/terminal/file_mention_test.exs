defmodule Ourocode.Terminal.FileMentionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.FileMention

  test "active_query reads the mention before the cursor" do
    assert FileMention.active_query("open @lib/ouro", 14) == "lib/ouro"
    assert FileMention.active_query("@", 1) == ""
    assert FileMention.active_query("open lib/ouro", 13) == nil
  end

  test "active_query ignores mentions after the cursor" do
    assert FileMention.active_query("open @lib later", 5) == nil
    assert FileMention.active_query("open @lib later", String.length("open @lib")) == "lib"
  end

  test "replace_active swaps the active mention and preserves trailing text" do
    assert FileMention.replace_active("open @term now", String.length("open @term"), "lib/tui.ex") ==
             {"open @lib/tui.ex  now", String.length("open @lib/tui.ex ")}
  end

  test "replace_active appends a mention when none is active" do
    assert FileMention.replace_active("open file", 4, "lib/tui.ex") ==
             {"open file@lib/tui.ex ", String.length("open file@lib/tui.ex ")}
  end

  test "label uses parent directory or project file fallback" do
    assert FileMention.label("README.md") == "project file"
    assert FileMention.label("lib/ourocode/terminal/tui.ex") == "lib/ourocode/terminal"
  end
end
