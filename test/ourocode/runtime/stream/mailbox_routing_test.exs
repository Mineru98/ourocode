defmodule Ourocode.Runtime.Stream.MailboxRoutingTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Stream.MailboxRouting

  test "routes backpressure only for notifying behaviors" do
    pressure = %{event_seq: 1}

    assert :ok =
             MailboxRouting.route_backpressure(
               %{
                 stream_mailbox_backpressure_behavior: :notify,
                 stream_mailbox_backpressure_target: self()
               },
               pressure
             )

    assert_receive {:stream_mailbox_backpressure, ^pressure}

    assert :ok =
             MailboxRouting.route_backpressure(
               %{
                 stream_mailbox_backpressure_behavior: :none,
                 stream_mailbox_backpressure_target: self()
               },
               pressure
             )

    refute_receive {:stream_mailbox_backpressure, _pressure}, 10
  end

  test "routes overflow, rendered events, and final flush events" do
    overflow = %{dropped_event_seq: 3}
    event = %{event_seq: 2}
    flush = %{reason: :stream_completed}

    assert :ok =
             MailboxRouting.route_overflow(
               %{stream_mailbox_overflow_path: :notify, stream_mailbox_overflow_target: self()},
               overflow
             )

    assert :ok =
             MailboxRouting.route_rendered_event(
               %{stream_mailbox_rendered_event_target: self()},
               event
             )

    assert :ok =
             MailboxRouting.route_final_flush(
               %{stream_mailbox_final_flush_target: self()},
               flush
             )

    assert_receive {:stream_mailbox_overflow, ^overflow}
    assert_receive {:stream_mailbox_rendered_event, ^event}
    assert_receive {:stream_mailbox_final_flush, ^flush}
  end

  test "routes buffered events to supported subscriber shapes and ignores invalid subscribers" do
    event = %{event_seq: 4, content: "hello"}

    state =
      MailboxRouting.route_buffered_event(
        %{
          stream_event_subscribers: [
            self(),
            {self(), :custom_stream_event},
            {self(), :tagged_stream_event, %{source: :mailbox}},
            :invalid
          ]
        },
        event
      )

    assert state.stream_event_subscribers |> length() == 4
    assert_receive {:stream_event, ^event}
    assert_receive {:custom_stream_event, ^event}
    assert_receive {:tagged_stream_event, %{source: :mailbox, event_seq: 4, content: "hello"}}
  end
end
