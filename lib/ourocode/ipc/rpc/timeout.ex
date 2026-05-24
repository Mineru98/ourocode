defmodule Ourocode.IPC.RPC.Timeout do
  @moduledoc """
  Timeout helpers for helper RPC requests.
  """

  @spec normalize(timeout()) :: {:ok, timeout()} | {:error, {:invalid_timeout, term()}}
  def normalize(:infinity), do: {:ok, :infinity}
  def normalize(timeout) when is_integer(timeout) and timeout > 0, do: {:ok, timeout}
  def normalize(timeout), do: {:error, {:invalid_timeout, timeout}}

  @spec call_timeout(timeout()) :: timeout()
  def call_timeout(:infinity), do: :infinity
  def call_timeout(timeout) when is_integer(timeout), do: timeout + 1_000

  @spec schedule(String.t(), timeout()) :: reference() | nil
  def schedule(_request_id, :infinity), do: nil

  def schedule(request_id, timeout) when is_binary(request_id) and is_integer(timeout) do
    Process.send_after(self(), {:request_timeout, request_id}, timeout)
  end

  @spec cancel(reference() | nil) :: :ok | false | non_neg_integer()
  def cancel(nil), do: :ok
  def cancel(timer), do: Process.cancel_timer(timer)
end
