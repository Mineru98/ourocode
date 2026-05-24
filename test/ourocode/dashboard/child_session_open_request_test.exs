defmodule Ourocode.Dashboard.ChildSessionOpenRequestTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionOpenRequest

  test "normalize_identifier trims valid runtime identifiers and rejects blanks" do
    assert ChildSessionOpenRequest.normalize_identifier(" child-alpha ") == {:ok, "child-alpha"}

    assert ChildSessionOpenRequest.normalize_identifier("  ") ==
             {:error, :invalid_child_session_identifier}
  end

  test "child_id unwraps pane identifiers before request creation" do
    assert ChildSessionOpenRequest.child_id("child-session:child-alpha") == {:ok, "child-alpha"}

    assert ChildSessionOpenRequest.child_id("child-session: ") ==
             {:error, :invalid_child_session_identifier}
  end

  test "pane_id reuses registry mappings before generating a stable pane id" do
    assert ChildSessionOpenRequest.pane_id(
             %{"child-alpha" => "child-session:existing-alpha"},
             "child-alpha"
           ) == "child-session:existing-alpha"

    assert ChildSessionOpenRequest.pane_id(%{}, "child-bravo") == "child-session:child-bravo"
  end

  test "build creates a journal-ready child-session create-open request" do
    assert %{
             action: :create_open,
             kind: :child_session_create_open_request,
             child_id: "child-alpha",
             pane_id: "child-session:child-alpha",
             selected_identifier: "child-alpha",
             parent_call_id: "parent-1",
             runtime_source: "opencode",
             transport: :sse,
             external_ids: %{"job_id" => "job-1", "childID" => "child-alpha"},
             stream_cursor: %{event_seq: 10},
             pane_state: %{
               open?: true,
               focused?: true,
               renderer: :default_child_session,
               title: "Alpha"
             }
           } =
             ChildSessionOpenRequest.build(
               "child-alpha",
               "child-alpha",
               "child-session:child-alpha",
               parent_call_id: "parent-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{"job_id" => "job-1"},
               stream_cursor: %{event_seq: 10},
               pane_state: %{title: "Alpha"}
             )
  end

  test "metadata converts a create-open request into register_child_pane metadata" do
    request =
      ChildSessionOpenRequest.build(
        "child-alpha",
        "child-alpha",
        "child-session:child-alpha",
        parent_call_id: "parent-1",
        runtime_source: "opencode",
        transport: :sse,
        external_ids: %{},
        stream_cursor: %{event_seq: 10},
        pane_state: %{title: "Alpha"}
      )

    assert %{
             child_id: "child-alpha",
             parent_call_id: "parent-1",
             runtime_source: "opencode",
             transport: :sse,
             external_ids: %{"childID" => "child-alpha"},
             stream_cursor: %{event_seq: 10},
             pane_state: %{
               open?: true,
               focused?: false,
               renderer: :default_child_session,
               title: "Alpha"
             }
           } = ChildSessionOpenRequest.metadata(request, false)
  end
end
