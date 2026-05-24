defmodule Ourocode.Journal.CleanupEventTypeTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.CleanupEventType

  test "category classifies cleanup events from atom or string fields" do
    assert CleanupEventType.category(%{type: :transport_cleanup}) ==
             {:ok, :cleanup, :transport_cleanup}

    assert CleanupEventType.category(%{"event_type" => "stream_cleanup"}) ==
             {:ok, :cleanup, :stream_cleanup}
  end

  test "category classifies orphan candidates, completions, and failures" do
    assert CleanupEventType.category(%{type: :child_pane_opened}) ==
             {:ok, :orphan_candidate, :child_pane_opened}

    assert CleanupEventType.category(%{type: "child_pane_completed"}) ==
             {:ok, :completion, :child_pane_completed}

    assert CleanupEventType.category(%{event_type: "transport_decode_failed"}) ==
             {:ok, :failure, :transport_decode_failed}
  end

  test "category ignores unknown or missing event types" do
    assert CleanupEventType.category(%{type: :unknown_event}) == :error

    assert CleanupEventType.category(%{type: " parent_call_failed "}) ==
             {:ok, :failure, :parent_call_failed}

    assert CleanupEventType.category(%{}) == :error
  end
end
