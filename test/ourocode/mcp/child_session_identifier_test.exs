defmodule Ourocode.MCP.ChildSessionIdentifierTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.ChildSessionIdentifier

  test "normalizes explicit child identity aliases" do
    examples = [
      {%{"childID" => " child-1 "}, :childID},
      {%{childId: "child-1"}, :childId},
      {%{"child_id" => "child-1"}, :child_id},
      {%{"childSessionID" => "child-1"}, :child_session_id},
      {%{agentSessionId: "child-1"}, :agent_session_id},
      {%{"opencode_childID" => "child-1"}, :opencode_child_id}
    ]

    for {payload, source} <- examples do
      assert ChildSessionIdentifier.explicit_child_id(payload) == {"child-1", source}
    end
  end

  test "extracts child identity from pane keys only with the child-session prefix" do
    assert ChildSessionIdentifier.explicit_child_id(%{
             "pane_key" => " child-session:child-pane-1 "
           }) == {"child-pane-1", :pane_key}

    assert ChildSessionIdentifier.explicit_child_id(%{"pane_key" => "child-pane-1"}) == nil
  end

  test "detects malformed explicit child identity values" do
    for malformed <- [nil, "", "   ", 42, :child_atom, ["child-list"], %{"id" => "child-map"}] do
      assert ChildSessionIdentifier.malformed_child_id_payload?(%{"childID" => malformed})
    end

    assert ChildSessionIdentifier.malformed_child_id_payload?(%{
             "pane_key" => "not-a-child-pane"
           })

    refute ChildSessionIdentifier.malformed_child_id_payload?(%{"childID" => "child-1"})
    refute ChildSessionIdentifier.malformed_child_id_payload?(%{"seq" => 1})
  end

  test "builds stable child pane keys" do
    assert ChildSessionIdentifier.pane_key("child-1") == "child-session:child-1"
  end
end
