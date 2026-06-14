defmodule Ourocode.Runtime.LoopBindingParentCallTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.LoopBindingEventFlow
  alias Ourocode.Runtime.LoopBindingParentCall
  alias Ourocode.Runtime.LoopBindingState

  test "build relays streamed events into the bindings inbox and returns worker result" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    event = %{
      type: :parent_call_event,
      event_seq: 1,
      parent_call_id: "parent-relay-1",
      transport: :streamable_http,
      runtime_source: "ouroboros"
    }

    parent_call =
      LoopBindingParentCall.build(agent, %{}, "parent-relay-1", "http://127.0.0.1:4000/mcp",
        execute_parent_call: fn opts, payload ->
          send(opts[:subscriber], {:ourocode_event, event})
          {:ok, %{payload: payload, url: opts[:url], parent_call_id: opts[:parent_call_id]}}
        end,
        flush: fn _agent -> :ok end
      )

    assert {:ok, result} = parent_call.(%{"name" => "ooo.interview"})
    assert result.payload == %{"name" => "ooo.interview"}
    assert result.url == "http://127.0.0.1:4000/mcp"
    assert result.parent_call_id == "parent-relay-1"

    poll = LoopBindingEventFlow.poll_fun(agent)
    assert {:ok, ^event} = poll.(%{})
    assert :none = poll.(%{})
  end

  test "build returns a transport error when the worker exceeds the hard timeout" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    test_pid = self()

    parent_call =
      LoopBindingParentCall.build(agent, %{}, "parent-timeout-1", "http://127.0.0.1:4000/mcp",
        execute_parent_call: fn _opts, _payload ->
          send(test_pid, {:worker_started, self()})

          receive do
            :never -> :ok
          end
        end,
        flush: fn _agent -> :ok end,
        timeout: 20
      )

    assert {:error, {:parent_call_timeout, 20}} = parent_call.(%{"name" => "ooo.interview"})
    assert_receive {:worker_started, worker}, 100
    Process.sleep(10)
    refute Process.alive?(worker)
  end

  test "build returns a transport error when the worker exits before sending a result" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    parent_call =
      LoopBindingParentCall.build(agent, %{}, "parent-exit-1", "http://127.0.0.1:4000/mcp",
        execute_parent_call: fn _opts, _payload -> Process.exit(self(), :boom) end,
        flush: fn _agent -> :ok end,
        timeout: 1_000
      )

    assert {:error, {:parent_call_worker_exit, :boom}} =
             parent_call.(%{"name" => "ooo.interview"})
  end
end
