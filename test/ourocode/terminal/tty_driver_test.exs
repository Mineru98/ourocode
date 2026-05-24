defmodule Ourocode.Terminal.TtyDriverTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.TtyDriver

  test "helper_path picks the first existing path" do
    dir = System.tmp_dir!()
    missing = Path.join(dir, "ourocode-tty-missing-#{System.unique_integer([:positive])}")
    existing = Path.join(dir, "ourocode-tty-existing-#{System.unique_integer([:positive])}")

    File.write!(existing, "")
    on_exit(fn -> File.rm(existing) end)

    assert TtyDriver.helper_path([nil, missing, existing]) == existing
  end

  test "terminal control sequences leave mouse drag selection to the host terminal" do
    refute TtyDriver.enter_sequence() =~ "?1000h"
    refute TtyDriver.enter_sequence() =~ "?1006h"
    refute TtyDriver.exit_sequence() =~ "?1000l"
    refute TtyDriver.exit_sequence() =~ "?1006l"
  end

  test "parse_header accepts complete helper header and preserves key bytes" do
    assert TtyDriver.parse_header("120 40\nabc") == {:ok, 120, 40, "abc"}
    assert TtyDriver.parse_header("120") == :partial
    assert TtyDriver.parse_header("0 40\n") == :error
    assert TtyDriver.parse_header("bad header\n") == :error
  end

  test "next_chunk surfaces file-cache notifications and poll ticks" do
    send(self(), {:file_cache_ready, ["lib/a.ex"]})
    assert TtyDriver.next_chunk(nil, 0) == {:file_cache_ready, ["lib/a.ex"]}
    assert TtyDriver.next_chunk(nil, 0) == :tick
  end
end
