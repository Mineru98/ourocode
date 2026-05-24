defmodule Ourocode.Runtime.Stream.Resources do
  @moduledoc """
  Registered resource release for supervised runtime streams.
  """

  alias Ourocode.Runtime.Stream.Mailbox

  @type released_resources :: %{
          required(:process_handles) => non_neg_integer(),
          required(:subscriptions) => non_neg_integer(),
          required(:registered_buffers) => non_neg_integer(),
          required(:ets_entries) => non_neg_integer(),
          required(:pending_events) => non_neg_integer()
        }

  @spec release_registered(map()) :: {map(), released_resources()}
  def release_registered(state) when is_map(state) do
    process_handle_count = length(Map.get(state, :stream_process_handles, []))
    subscription_count = length(Map.get(state, :stream_subscriptions, []))
    registered_buffer_count = length(Map.get(state, :stream_registered_buffers, []))

    state |> Map.get(:stream_process_handles, []) |> Enum.each(&release_process_handle/1)
    state |> Map.get(:stream_subscriptions, []) |> Enum.each(&release_subscription/1)

    ets_entry_count =
      state
      |> Map.get(:stream_registered_buffers, [])
      |> release_registered_buffers()

    {state, pending_event_count} = Mailbox.release_buffers(state)

    released_resources = %{
      process_handles: process_handle_count,
      subscriptions: subscription_count,
      registered_buffers: registered_buffer_count,
      ets_entries: ets_entry_count,
      pending_events: pending_event_count
    }

    state =
      state
      |> Map.put(:stream_process_handles, [])
      |> Map.put(:stream_subscriptions, [])
      |> Map.put(:stream_registered_buffers, [])

    {state, released_resources}
  end

  defp release_process_handle(port) when is_port(port) do
    if Port.info(port) do
      Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp release_process_handle(_resource), do: :ok

  defp release_subscription(fun) when is_function(fun, 0) do
    fun.()
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp release_subscription(fun) when is_function(fun, 1) do
    fun.(:unsubscribe)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp release_subscription({:unsubscribe, pid, message}) when is_pid(pid) do
    send(pid, message)
    :ok
  end

  defp release_subscription({:timer, timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp release_subscription({:monitor, monitor_ref}) when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  defp release_subscription(pid) when is_pid(pid) do
    send(pid, {:unsubscribe, self()})
    :ok
  end

  defp release_subscription(_resource), do: :ok

  defp release_registered_buffers(buffers) do
    Enum.reduce(buffers, 0, fn buffer, acc ->
      acc + release_registered_buffer(buffer)
    end)
  end

  defp release_registered_buffer({:ets, table}), do: release_ets_entries(table)
  defp release_registered_buffer({:ets_table, table}), do: release_ets_entries(table)
  defp release_registered_buffer(%{ets_table: table}), do: release_ets_entries(table)
  defp release_registered_buffer(_buffer), do: 0

  defp release_ets_entries(table) do
    case :ets.info(table, :size) do
      size when is_integer(size) ->
        :ets.delete_all_objects(table)
        size

      :undefined ->
        0
    end
  rescue
    ArgumentError -> 0
  end
end
