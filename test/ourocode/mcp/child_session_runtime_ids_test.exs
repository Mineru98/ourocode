defmodule Ourocode.MCP.ChildSessionRuntimeIdsTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.ChildSessionRuntimeIds

  test "preferred returns the highest precedence runtime id" do
    assert ChildSessionRuntimeIds.preferred(%{
             external_ids: %{
               "session_id" => "session-1",
               "thread_id" => "thread-1",
               "job_id" => " job-1 "
             }
           }) == {:job_id, "job-1"}
  end

  test "preferred uses explicit fallback runtime metadata before parsed event ids" do
    assert ChildSessionRuntimeIds.preferred(%{
             fallback_runtime_metadata: %{"lineage_id" => "lineage-override"},
             external_ids: %{"job_id" => "job-1"}
           }) == {:lineage_id, "lineage-override"}
  end

  test "preferred reads nested input ids and request id fallback" do
    assert ChildSessionRuntimeIds.preferred(%{
             fallback_runtime_metadata: %{
               input: %{"sessionID" => "input-session-1", "callID" => "call-1"}
             }
           }) == {:input_session_id, "input-session-1"}

    assert ChildSessionRuntimeIds.preferred(%{request_id: 42}) == {:request_id, "42"}
  end

  test "value normalizes string and integer ids" do
    assert ChildSessionRuntimeIds.value(%{"parent_call_id" => " parent-1 "}, :parent_call_id) ==
             "parent-1"

    assert ChildSessionRuntimeIds.value(%{parent_call_id: 7}, :parent_call_id) == "7"
    assert ChildSessionRuntimeIds.value(%{parent_call_id: " "}, :parent_call_id) == nil
  end
end
