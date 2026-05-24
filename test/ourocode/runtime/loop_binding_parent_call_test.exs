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
end
