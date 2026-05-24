defmodule Ourocode.MCP.ChildSessionPayloadsTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.ChildSessionPayloads

  test "collects supported child-session payload candidate maps" do
    event = %{
      "data" => %{"params" => %{"childID" => "from-data"}},
      notification: %{"params" => %{"childID" => "from-notification"}},
      raw_event: %{data: %{result: %{"childID" => "from-raw-result"}}},
      result: "not-a-map"
    }

    paths = event |> ChildSessionPayloads.candidates() |> Enum.map(&elem(&1, 0))

    assert :event in paths
    assert :data in paths
    assert :data_params in paths
    assert :notification in paths
    assert :notification_params in paths
    assert :raw_event in paths
    assert :raw_event_data in paths
    assert :raw_event_data_result in paths
    refute :result in paths
  end

  test "reads atom and string fields without creating new atoms" do
    assert ChildSessionPayloads.field(%{"external_ids" => %{session_id: "s1"}}, :external_ids) ==
             %{session_id: "s1"}

    assert ChildSessionPayloads.nested(%{raw_event: %{"params" => %{childID: "c1"}}}, [
             :raw_event,
             "params"
           ]) == %{childID: "c1"}

    assert ChildSessionPayloads.any(%{"type" => "parent_call_event"}, [:type, "type"]) ==
             "parent_call_event"
  end
end
