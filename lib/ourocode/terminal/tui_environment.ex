defmodule Ourocode.Terminal.TuiEnvironment do
  @moduledoc """
  Runtime environment checks for attaching the interactive TUI.
  """

  alias Ourocode.Terminal.TtyDriver
  alias Ourocode.Terminal.TuiDriverSession

  @spec interactive?(map() | keyword()) :: boolean()
  def interactive?(options) do
    options = Map.new(options)
    input = Map.get(options, :input, :stdio)
    output = Map.get(options, :output, :stdio)

    stdio_device?(input) and stdio_device?(output) and Map.get(options, :read_line) == nil and
      not test_run?() and TtyDriver.tty?() and helper_path() != nil
  end

  @spec helper_path() :: String.t() | nil
  def helper_path, do: TuiDriverSession.helper_path()

  @spec terminal_enter_sequence() :: String.t()
  def terminal_enter_sequence, do: TuiDriverSession.enter_sequence()

  @spec terminal_exit_sequence() :: String.t()
  def terminal_exit_sequence, do: TuiDriverSession.exit_sequence()

  @spec test_run?() :: boolean()
  def test_run?, do: is_pid(Process.whereis(ExUnit.Server))

  @spec stdio_device?(term()) :: boolean()
  def stdio_device?(:stdio), do: true
  def stdio_device?(:standard_io), do: true
  def stdio_device?(_other), do: false
end
