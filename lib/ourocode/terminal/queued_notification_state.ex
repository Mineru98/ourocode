defmodule Ourocode.Terminal.QueuedNotificationState do
  @moduledoc """
  Shared queued-notification state projection helpers.

  Runtime state can expose the queue through a few nested shapes. This module
  keeps that lookup and pending-count policy out of terminal renderers.
  """

  alias Ourocode.Terminal.{
    QueuedNotificationFields,
    QueuedNotificationItems
  }

  @doc """
  Finds queued notification state from a terminal startup result.
  """
  @spec from_startup_result(map()) :: map()
  def from_startup_result(%{runtime: %{queued_notifications: queue_state}})
      when is_map(queue_state),
      do: queue_state

  def from_startup_result(%{context: %{runtime: %{queued_notifications: queue_state}}})
      when is_map(queue_state),
      do: queue_state

  def from_startup_result(%{context: %{queued_notifications: queue_state}})
      when is_map(queue_state),
      do: queue_state

  def from_startup_result(%{queued_notifications: queue_state}) when is_map(queue_state),
    do: queue_state

  def from_startup_result(_startup_result), do: %{}

  @doc """
  Counts pending queue items, honoring a runtime-provided pending_count when set.
  """
  @spec pending_count(map()) :: non_neg_integer()
  def pending_count(queue_state) when is_map(queue_state) do
    case QueuedNotificationFields.value(queue_state, :pending_count) do
      count when is_integer(count) and count >= 0 ->
        count

      _count ->
        queue_state
        |> items()
        |> QueuedNotificationItems.pending_items()
        |> length()
    end
  end

  def pending_count(_queue_state), do: 0

  @doc """
  Returns raw queued notification items from queue state.
  """
  @spec items(map()) :: [term()]
  def items(queue_state) when is_map(queue_state) do
    case QueuedNotificationFields.value(queue_state, :items) do
      items when is_list(items) -> items
      _items -> []
    end
  end

  def items(_queue_state), do: []
end
