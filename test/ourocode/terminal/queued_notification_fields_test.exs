defmodule Ourocode.Terminal.QueuedNotificationFieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.QueuedNotificationFields

  test "looks up atom and string keys without dropping false values" do
    assert QueuedNotificationFields.value(%{replayable?: false}, :replayable?, true) == false
    assert QueuedNotificationFields.value(%{"id" => "queued-1"}, :id) == "queued-1"
    assert QueuedNotificationFields.value(%{}, :id, "notification") == "notification"
  end

  test "coerces renderable text values" do
    assert QueuedNotificationFields.text(%{source: :runtime}, :source) == "runtime"
    assert QueuedNotificationFields.text(%{event_seq: 12}, :event_seq) == "12"
    assert QueuedNotificationFields.text(%{payload: %{}}, :payload) == nil
  end

  test "normalizes terminal text" do
    assert QueuedNotificationFields.terminal_safe(" hello\n\tworld\r ") == "hello world"
  end
end
