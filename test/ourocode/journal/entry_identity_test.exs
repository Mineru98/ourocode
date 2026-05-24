defmodule Ourocode.Journal.EntryIdentityTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.EntryIdentity

  test "child_event_identity builds stable length-prefixed identity components" do
    entry = %{
      event_seq: 11,
      parent_call_id: "parent-1",
      runtime_source: "opencode",
      transport: :sse,
      payload: %{"childID" => "child-1", "seq" => "7"}
    }

    assert EntryIdentity.child_event_identity(entry) ==
             {:ok,
              "child-event:parent=8:parent-1:child=7:child-1:runtime=8:opencode:transport=3:sse:event_seq=2:11:runtime_seq=1:7"}
  end

  test "child_id falls back through external ids, payload, and raw event params" do
    assert EntryIdentity.child_id(%{external_ids: %{"child_id" => "child-external"}}) ==
             "child-external"

    assert EntryIdentity.child_id(%{payload: %{"childID" => "child-payload"}}) ==
             "child-payload"

    assert EntryIdentity.child_id(%{
             raw_event: %{"data" => %{"params" => %{"childID" => "child-raw"}}}
           }) == "child-raw"
  end

  test "child_event_identity rejects entries without child id or event seq" do
    assert EntryIdentity.child_event_identity(%{event_seq: 1}) ==
             {:error, :missing_child_event_identity}

    assert EntryIdentity.child_event_identity(%{child_id: "child-1"}) ==
             {:error, :missing_child_event_identity}
  end
end
