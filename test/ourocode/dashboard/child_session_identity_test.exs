defmodule Ourocode.Dashboard.ChildSessionIdentityTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionIdentity

  test "normalizes non-empty child ids by trimming whitespace" do
    assert ChildSessionIdentity.registry_child_id(" child-1 ") == "child-1"
    assert ChildSessionIdentity.registry_child_id("   ") == "   "
  end

  test "builds stable generated pane ids" do
    assert ChildSessionIdentity.child_pane_id(" child-1 ") == "child-session:child-1"
    assert ChildSessionIdentity.pane_id("child-1") == "child-session:child-1"
  end

  test "register_child_id keeps existing registry keys stable" do
    registry = %{"child-1" => "child-session:custom"}

    assert ChildSessionIdentity.register_child_id(registry, " child-1 ") == registry
  end

  test "register_child_id can reuse an existing pane id for a child id" do
    assert ChildSessionIdentity.register_child_id(%{}, "child-1", %{id: "child-pane:recovered"}) ==
             %{"child-1" => "child-pane:recovered"}
  end

  test "child_pane_key returns existing or generated registry key" do
    assert ChildSessionIdentity.child_pane_key(%{"child-1" => "child-pane:existing"}, "child-1") ==
             "child-pane:existing"

    assert ChildSessionIdentity.child_pane_key(%{}, " child-2 ") == "child-session:child-2"
  end
end
