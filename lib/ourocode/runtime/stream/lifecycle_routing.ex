defmodule Ourocode.Runtime.Stream.LifecycleRouting do
  @moduledoc """
  Notification routing for stream lifecycle cleanup events.
  """

  alias Ourocode.Runtime.Stream.CleanupEvent

  @spec route_operation_timeout(map(), map()) :: :ok
  def route_operation_timeout(%{stream_operation_timeout_target: pid}, cleanup)
      when is_pid(pid) do
    send(pid, {:stream_operation_timeout, cleanup})
    :ok
  end

  def route_operation_timeout(_state, _cleanup), do: :ok

  @spec route_timeout_termination(map(), map()) :: :ok
  def route_timeout_termination(%{stream_cleanup_action: :stop} = state, cleanup) do
    route_lifecycle(state, CleanupEvent.timeout_termination(cleanup))
  end

  def route_timeout_termination(_state, _cleanup), do: :ok

  @spec route_lifecycle(map(), map()) :: :ok
  def route_lifecycle(%{stream_lifecycle_target: pid}, event) when is_pid(pid) do
    send(pid, {:stream_lifecycle_event, event})
    :ok
  end

  def route_lifecycle(%{stream_lifecycle_target: fun}, event) when is_function(fun, 1) do
    fun.(event)
    :ok
  end

  def route_lifecycle(_state, _event), do: :ok

  @spec route_cleanup(map(), map()) :: :ok
  def route_cleanup(%{stream_cleanup_target: pid}, cleanup) when is_pid(pid) do
    send(pid, {:stream_stale_cleanup, cleanup})
    :ok
  end

  def route_cleanup(_state, _cleanup), do: :ok
end
