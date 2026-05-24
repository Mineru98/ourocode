defmodule Ourocode.Dashboard.ChildSessionPaneLookupTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneLookup

  test "find_existing locates panes by pane id, registered child id, child id, or external id" do
    panes = [
      %{
        id: "pane-alpha",
        child_id: "child-alpha",
        external_ids: %{"session_id" => "session-alpha"}
      },
      %{id: "pane-bravo", child_id: "child-bravo", external_ids: %{"thread_id" => "thread-bravo"}}
    ]

    registry = %{"registered-bravo" => "pane-bravo"}

    assert %{id: "pane-alpha"} =
             ChildSessionPaneLookup.find_existing(panes, registry, "pane-alpha")

    assert %{id: "pane-bravo"} =
             ChildSessionPaneLookup.find_existing(panes, registry, "registered-bravo")

    assert %{id: "pane-alpha"} =
             ChildSessionPaneLookup.find_existing(panes, registry, "child-alpha")

    assert %{id: "pane-bravo"} =
             ChildSessionPaneLookup.find_existing(panes, registry, "thread-bravo")
  end

  test "external_id_matches? searches nested runtime id maps and lists" do
    external_ids = %{
      "metadata" => %{"session_id" => "session-nested"},
      "children" => [
        %{"thread_id" => "thread-list"},
        %{"ignored" => "plain-value"}
      ]
    }

    assert ChildSessionPaneLookup.external_id_matches?(external_ids, "session-nested")
    assert ChildSessionPaneLookup.external_id_matches?(external_ids, "thread-list")
    refute ChildSessionPaneLookup.external_id_matches?(external_ids, "plain-value")
  end

  test "strongest_session_identifiers prefers native session ids over weaker ids" do
    external_ids = %{
      "session_id" => "session-weaker",
      "thread_id" => "thread-middle",
      nested: %{"native_session_id" => "native-stronger"}
    }

    assert ChildSessionPaneLookup.strongest_session_identifiers(external_ids) == [
             "native-stronger"
           ]
  end

  test "reusable_session_pane uses the strongest available session identity" do
    panes = [
      %{id: "pane-session", external_ids: %{"session_id" => "shared-session"}},
      %{id: "pane-native", external_ids: %{"native_session_id" => "shared-native"}}
    ]

    assert %{id: "pane-native"} =
             ChildSessionPaneLookup.reusable_session_pane(panes, %{
               "session_id" => "shared-session",
               "native_session_id" => "shared-native"
             })
  end
end
