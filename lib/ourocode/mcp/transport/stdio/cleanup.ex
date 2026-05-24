defmodule Ourocode.MCP.Transport.Stdio.Cleanup do
  @moduledoc """
  Idle cleanup and owned port helpers for stdio transports.
  """

  alias Ourocode.Config

  @spec timeout_ms(keyword()) :: pos_integer() | :infinity
  def timeout_ms(opts) when is_list(opts) do
    Keyword.get(opts, :stale_cleanup_timeout_ms, Config.defaults().stale_cleanup_timeout_ms)
  end

  @spec touch(map()) :: map()
  def touch(state) when is_map(state) do
    now_ms = monotonic_ms()

    state
    |> cancel_timer()
    |> Map.put(:last_activity_monotonic_ms, now_ms)
    |> Map.put(:cleanup_timer_ref, schedule_timer(state.cleanup_timeout_ms, now_ms))
  end

  @spec schedule_timer(:infinity | pos_integer(), integer()) :: reference() | nil
  def schedule_timer(:infinity, _last_activity_ms), do: nil

  def schedule_timer(timeout_ms, last_activity_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    Process.send_after(self(), {:stdio_cleanup_timeout, last_activity_ms}, timeout_ms)
  end

  @spec cancel_timer(map()) :: map()
  def cancel_timer(%{cleanup_timer_ref: nil} = state), do: state

  def cancel_timer(%{cleanup_timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    state
  end

  @spec close_owned_port(map()) :: map()
  def close_owned_port(state) when is_map(state) do
    close_port(state.port)
    state
  end

  @spec port_open?(port()) :: boolean()
  def port_open?(port) do
    !!Port.info(port)
  rescue
    ArgumentError -> false
  end

  @spec close_port(port()) :: :ok
  def close_port(port) do
    if Port.info(port) do
      Port.close(port)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)
end
