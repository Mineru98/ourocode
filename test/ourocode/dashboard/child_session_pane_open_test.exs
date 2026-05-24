defmodule Ourocode.Dashboard.ChildSessionPaneOpenTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneOpen
  alias Ourocode.Dashboard.ChildSessionPanes

  test "resolves an existing pane by child id" do
    state =
      ChildSessionPanes.new()
      |> register!("open-existing-child", "parent-open-existing")

    assert {:ok, resolution} = ChildSessionPaneOpen.resolve(state, "open-existing-child")

    assert resolution.kind == :existing_session
    assert resolution.child_id == "open-existing-child"
    assert resolution.pane_id == "child-session:open-existing-child"
    assert resolution.session.child_id == "open-existing-child"
  end

  test "resolves completed panes and nested runtime identifiers" do
    completed_pane = %{
      id: "child-session:completed-child",
      kind: :child_session,
      status: :completed,
      child_id: "completed-child",
      parent_call_id: "parent-completed",
      runtime_source: "codex",
      transport: :stdio,
      external_ids: %{"native_session_id" => "native-completed-1"},
      stream_cursor: %{event_seq: 12},
      pane_state: %{},
      created_at_ms: 1,
      updated_at_ms: 2
    }

    state = %{ChildSessionPanes.new() | completed: [completed_pane]}

    assert {:ok, resolution} =
             ChildSessionPaneOpen.resolve(state, "child-session:completed-child")

    assert resolution.kind == :existing_session
    assert resolution.session.status == :completed

    assert {:ok, resolution} = ChildSessionPaneOpen.resolve(state, "native-completed-1")
    assert resolution.pane_id == completed_pane.id

    state =
      ChildSessionPanes.new()
      |> register!("nested-child", "parent-nested", %{
        external_ids: %{
          "input" => %{
            "sessionID" => "input-session-1",
            "callID" => "input-call-1"
          }
        }
      })

    assert {:ok, %{pane_id: "child-session:nested-child"}} =
             ChildSessionPaneOpen.resolve(state, "input-session-1")

    assert {:ok, %{pane_id: "child-session:nested-child"}} =
             ChildSessionPaneOpen.resolve(state, "input-call-1")
  end

  test "builds a create-open request for a missing child id" do
    assert {:ok, resolution} =
             ChildSessionPaneOpen.resolve(
               ChildSessionPanes.new(),
               "open-missing-child",
               parent_call_id: "parent-open-missing",
               runtime_source: "runtime-open-test",
               transport: :sse
             )

    assert resolution.kind == :create_open_request
    assert resolution.child_id == "open-missing-child"
    assert resolution.pane_id == "child-session:open-missing-child"
    assert resolution.request.parent_call_id == "parent-open-missing"

    assert {:ok, resolution} =
             ChildSessionPaneOpen.resolve(ChildSessionPanes.new(), " child-session:new-pane-id ")

    assert resolution.kind == :create_open_request
    assert resolution.child_id == "new-pane-id"
    assert resolution.pane_id == "child-session:new-pane-id"
  end

  test "opens a missing child pane and focuses it when no pane is active" do
    assert {:ok, state} =
             ChildSessionPaneOpen.open(
               ChildSessionPanes.new(),
               "open-new-child",
               parent_call_id: "parent-open-new",
               runtime_source: "runtime-open-test",
               transport: :streamable_http
             )

    assert state.focused == "child-session:open-new-child"
    assert state.open == ["child-session:open-new-child"]
    assert [%{child_id: "open-new-child", pane_state: %{focused?: true}}] = state.working
  end

  test "opens existing resolutions without duplicating matching sessions" do
    state =
      ChildSessionPanes.new()
      |> register!("open-existing-child", "parent-open-existing", %{
        external_ids: %{"native_session_id" => "open-native-existing-1"}
      })
      |> Map.merge(%{focused: nil, open: []})

    assert {:ok, resolution} = ChildSessionPaneOpen.resolve(state, "open-native-existing-1")
    assert {:ok, opened} = ChildSessionPaneOpen.open_resolved(state, resolution)

    assert opened.focused == "child-session:open-existing-child"
    assert opened.open == ["child-session:open-existing-child"]
    assert Enum.map(opened.working, & &1.id) == ["child-session:open-existing-child"]

    assert {:ok, opened} =
             ChildSessionPaneOpen.open(
               state,
               "new-child-with-existing-session",
               parent_call_id: "parent-open-duplicate",
               runtime_source: "runtime-open-test",
               transport: :sse,
               external_ids: %{"native_session_id" => "open-native-existing-1"}
             )

    assert opened.focused == "child-session:open-existing-child"
    assert Enum.map(opened.working, & &1.id) == ["child-session:open-existing-child"]
  end

  test "rejects invalid identifiers and invalid state" do
    assert ChildSessionPaneOpen.resolve(ChildSessionPanes.new(), "  ") ==
             {:error, :invalid_child_session_identifier}

    assert ChildSessionPaneOpen.resolve(%{working: []}, "open-child") ==
             {:error, :invalid_child_session_state}
  end

  defp register!(state, child_id, parent_call_id, overrides \\ %{}) do
    assert {:ok, state} =
             ChildSessionPanes.register_child_pane(
               state,
               Map.merge(
                 %{
                   child_id: child_id,
                   parent_call_id: parent_call_id,
                   runtime_source: "runtime-open-test",
                   transport: :stdio
                 },
                 overrides
               )
             )

    state
  end
end
