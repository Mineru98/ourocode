defmodule Ourocode.Runtime.Stream.LifecycleRoutingTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Stream.LifecycleRouting

  test "routes operation timeout events to configured process targets" do
    cleanup = %{cleanup_reason: :operation_timeout}

    assert :ok =
             LifecycleRouting.route_operation_timeout(
               %{stream_operation_timeout_target: self()},
               cleanup
             )

    assert_receive {:stream_operation_timeout, ^cleanup}

    assert :ok = LifecycleRouting.route_operation_timeout(%{}, cleanup)
  end

  test "routes cleanup events to configured process targets" do
    cleanup = %{cleanup_reason: :idle_timeout}

    assert :ok =
             LifecycleRouting.route_cleanup(
               %{stream_cleanup_target: self()},
               cleanup
             )

    assert_receive {:stream_stale_cleanup, ^cleanup}

    assert :ok = LifecycleRouting.route_cleanup(%{}, cleanup)
  end

  test "routes lifecycle events to process and function targets" do
    event = %{lifecycle_type: :stream_terminated}

    assert :ok =
             LifecycleRouting.route_lifecycle(
               %{stream_lifecycle_target: self()},
               event
             )

    assert_receive {:stream_lifecycle_event, ^event}

    assert :ok =
             LifecycleRouting.route_lifecycle(
               %{
                 stream_lifecycle_target: fn routed ->
                   send(self(), {:function_target, routed})
                 end
               },
               event
             )

    assert_receive {:function_target, ^event}
  end

  test "routes timeout termination only when cleanup action stops the stream" do
    cleanup = %{
      cleanup_reason: :idle_timeout,
      stream_kind: :session,
      released_resources: %{}
    }

    assert :ok =
             LifecycleRouting.route_timeout_termination(
               %{stream_cleanup_action: :stop, stream_lifecycle_target: self()},
               cleanup
             )

    assert_receive {:stream_lifecycle_event,
                    %{
                      cleanup_reason: :idle_timeout,
                      lifecycle_type: :stream_terminated,
                      exit_state: :normal
                    }}

    assert :ok =
             LifecycleRouting.route_timeout_termination(
               %{stream_cleanup_action: :mark_stale, stream_lifecycle_target: self()},
               cleanup
             )

    refute_receive {:stream_lifecycle_event, _event}, 10
  end
end
