defmodule Ourocode.Terminal.TuiEnvironmentTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.TuiEnvironment

  test "stdio_device? accepts standard terminal aliases only" do
    assert TuiEnvironment.stdio_device?(:stdio)
    assert TuiEnvironment.stdio_device?(:standard_io)
    refute TuiEnvironment.stdio_device?(self())
  end

  test "interactive? is false for captured or custom read_line sessions" do
    {:ok, io} = StringIO.open("")

    refute TuiEnvironment.interactive?(%{input: io, output: io})

    refute TuiEnvironment.interactive?(%{
             input: :stdio,
             output: :stdio,
             read_line: fn _prompt -> :eof end
           })
  end

  test "interactive? is false while ExUnit is alive" do
    assert TuiEnvironment.test_run?()
    refute TuiEnvironment.interactive?(%{input: :stdio, output: :stdio})
  end

  test "terminal control sequences do not enable mouse reporting" do
    refute TuiEnvironment.terminal_enter_sequence() =~ "?1000h"
    refute TuiEnvironment.terminal_enter_sequence() =~ "?1006h"
    refute TuiEnvironment.terminal_exit_sequence() =~ "?1000l"
    refute TuiEnvironment.terminal_exit_sequence() =~ "?1006l"
  end
end
