defmodule Ourocode.Terminal.LiveResultTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.LiveResult

  test "merges live pane snapshot values over the stale result" do
    result = %{
      status: :healthy,
      interview: %{status: "stale"},
      pane_snapshot: fn -> %{interview: %{status: "live"}, paused: true} end
    }

    assert LiveResult.result(result).status == :healthy
    assert LiveResult.result(result).interview == %{status: "live"}
    assert LiveResult.result(result).paused == true
  end

  test "keeps the original result for invalid or failing snapshots" do
    invalid = %{status: :healthy, pane_snapshot: fn -> :not_a_map end}
    failing = %{status: :healthy, pane_snapshot: fn -> raise "boom" end}

    assert LiveResult.result(invalid) == invalid
    assert LiveResult.result(failing) == failing
  end

  test "keeps results without a snapshot unchanged" do
    result = %{status: :healthy}

    assert LiveResult.result(result) == result
  end
end
