defmodule Ourocode.Terminal.WorkspaceNavigationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.WorkspaceNavigation

  test "shortcut_action returns an enabled top-level command by shortcut" do
    workspace = %{
      actions: [
        %{shortcut: "p", command: "/plugins", enabled: true},
        %{shortcut: "v", command: "/verify", enabled: true}
      ]
    }

    assert WorkspaceNavigation.shortcut_action(workspace, "v") == "/verify"
    assert WorkspaceNavigation.shortcut_action(workspace, "V") == "/verify"
  end

  test "shortcut_action ignores disabled or missing commands" do
    workspace = %{
      actions: [
        %{shortcut: "v", command: "/verify", enabled: false},
        %{shortcut: "p", command: "", enabled: true}
      ]
    }

    assert WorkspaceNavigation.shortcut_action(workspace, "v") == nil
    assert WorkspaceNavigation.shortcut_action(workspace, "p") == nil
  end
end
