defmodule Ourocode.Runtime.Stream.ResourcesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Stream.Resources

  test "release_registered releases subscriptions, ets buffers, and resets resource lists" do
    table = :ets.new(:stream_resource_test, [:set, :private])
    :ets.insert(table, {:one, 1})
    :ets.insert(table, {:two, 2})

    parent = self()

    state = %{
      stream_process_handles: [:not_a_port],
      stream_subscriptions: [
        fn -> send(parent, :zero_arity_released) end,
        fn :unsubscribe -> send(parent, :one_arity_released) end,
        {:unsubscribe, parent, :tuple_released}
      ],
      stream_registered_buffers: [{:ets, table}, :unknown],
      stream_mailbox_pending: :queue.in(:pending, :queue.new()),
      stream_mailbox_pending_count: 1,
      stream_mailbox_draining?: true,
      stream_mailbox_backpressure_active?: false
    }

    assert {released_state, released_resources} = Resources.release_registered(state)
    assert released_state.stream_process_handles == []
    assert released_state.stream_subscriptions == []
    assert released_state.stream_registered_buffers == []

    assert released_resources == %{
             process_handles: 1,
             subscriptions: 3,
             registered_buffers: 2,
             ets_entries: 2,
             pending_events: 1
           }

    assert :ets.info(table, :size) == 0
    assert_received :zero_arity_released
    assert_received :one_arity_released
    assert_received :tuple_released
  end

  test "release_registered closes open ports" do
    command = System.find_executable("sh")
    assert is_binary(command)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        {:args, ["-c", "while IFS= read -r line; do :; done"]},
        {:line, 65_536}
      ])

    state = %{
      stream_process_handles: [port],
      stream_subscriptions: [],
      stream_registered_buffers: [],
      stream_mailbox_pending: :queue.new(),
      stream_mailbox_pending_count: 0,
      stream_mailbox_draining?: false,
      stream_mailbox_backpressure_active?: false
    }

    assert Port.info(port)

    assert {_released_state, %{process_handles: 1}} = Resources.release_registered(state)

    refute Port.info(port)
  end
end
