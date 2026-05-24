defmodule Ourocode.Terminal.RuntimeEventFlowTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.RuntimeEventFlow

  test "normalize_poll accepts empty, event, and error poller results" do
    assert RuntimeEventFlow.normalize_poll(nil) == :none
    assert RuntimeEventFlow.normalize_poll(:empty) == :none
    assert RuntimeEventFlow.normalize_poll({:ok, nil}) == :none
    assert RuntimeEventFlow.normalize_poll(%{type: :child_event}) == {:ok, %{type: :child_event}}
    assert RuntimeEventFlow.normalize_poll({:error, :closed}) == {:error, :closed}

    assert RuntimeEventFlow.normalize_poll(:bad) ==
             {:error, {:invalid_runtime_event_poll, :bad}}
  end

  test "poll supports zero- and one-arity pollers and reports exceptions as errors" do
    assert RuntimeEventFlow.poll(fn -> %{type: :hook_completed} end, %{}) ==
             {:ok, %{type: :hook_completed}}

    assert RuntimeEventFlow.poll(fn state -> %{type: state.type} end, %{type: :child_event}) ==
             {:ok, %{type: :child_event}}

    assert {:error, {:runtime_event_poller_exception, RuntimeError, "boom"}} =
             RuntimeEventFlow.poll(fn _state -> raise "boom" end, %{})
  end

  test "normalize_event fills terminal runtime defaults and keeps unknown string types" do
    known = RuntimeEventFlow.normalize_event(%{"event_type" => "child_event"})

    assert known.type == :child_event
    assert known.event_type == :child_event
    assert known.source == :runtime
    assert is_integer(known.occurred_at_ms)

    unknown = RuntimeEventFlow.normalize_event(%{type: "future_event"})

    assert unknown.type == "future_event"
    assert unknown.event_type == "future_event"
  end

  test "recoverable_event recognizes explicit recoverable runtime events" do
    assert RuntimeEventFlow.recoverable_event?(%{recoverable?: true})
    assert RuntimeEventFlow.recoverable_event?(%{severity: :recoverable})
    assert RuntimeEventFlow.recoverable_event?(%{type: :recoverable_stream_gap})
    refute RuntimeEventFlow.recoverable_event?(%{type: :child_event})
  end

  test "recoverable_error_event builds the journalable terminal error envelope" do
    event = RuntimeEventFlow.recoverable_error_event(:runtime_event_poll_failed, :closed, :poller)

    assert event.type == :terminal_recoverable_error
    assert event.event_type == :terminal_recoverable_error
    assert event.source == :poller
    assert event.recoverable? == true
    assert event.error_type == :runtime_event_poll_failed
    assert event.reason == :closed
    assert event.payload == %{error_type: :runtime_event_poll_failed, reason: :closed}
  end
end
