defmodule Ourocode.Runtime.LoopBindingEventFlowTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.LoopBindingEventFlow
  alias Ourocode.Runtime.LoopBindingState

  test "enqueue folds events and poll_fun drains them FIFO" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    first = %{type: :test_event, event_seq: 1}
    second = %{type: :test_event, event_seq: 2}

    assert :ok = LoopBindingEventFlow.enqueue(agent, first)
    assert :ok = LoopBindingEventFlow.enqueue(agent, second)

    poll = LoopBindingEventFlow.poll_fun(agent)

    assert {:ok, ^first} = poll.(%{})
    assert {:ok, ^second} = poll.(%{})
    assert :none = poll.(%{})
  end

  test "runtime_event_fun keeps event-loop bookkeeping hook a no-op" do
    handler = LoopBindingEventFlow.runtime_event_fun(self())

    assert handler.(%{type: :anything}, %{}) == :ok
  end
end
