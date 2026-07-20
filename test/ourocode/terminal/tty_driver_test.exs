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

  test "terminal lifecycle sequences enable and disable modes in restoration order" do
    assert TtyDriver.enter_sequence() ==
             "\e[?1049h\e[?1006h\e[?1003h\e[?2004h\e[?25l\e[2J\e[H"

    assert TtyDriver.exit_sequence() ==
             "\e[?2004l\e[?1003l\e[?1006l\e[?25h\e[?1049l"
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
