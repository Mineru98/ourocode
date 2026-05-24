defmodule Ourocode.Terminal.Notifications do
  @moduledoc """
  Pure state transitions for short-lived TUI notifications.
  """

  @limit 3

  @spec active(map(), integer()) :: {[String.t()], map()}
  def active(state, now_ms) when is_map(state) and is_integer(now_ms) do
    active =
      state
      |> Map.get(:notifications, [])
      |> Enum.filter(fn {_text, until_ms} -> until_ms > now_ms end)
      |> Enum.take(@limit)

    {Enum.map(active, fn {text, _until_ms} -> text end), %{state | notifications: active}}
  end

  @spec push(map(), String.t(), integer(), pos_integer()) :: map()
  def push(state, text, now_ms, ttl_ms)
      when is_map(state) and is_binary(text) and is_integer(now_ms) and is_integer(ttl_ms) do
    notifications =
      [{text, now_ms + ttl_ms} | Map.get(state, :notifications, [])]
      |> Enum.take(@limit)

    %{state | notifications: notifications}
  end

  @spec clear(map()) :: map()
  def clear(state) when is_map(state), do: %{state | notifications: []}
end
