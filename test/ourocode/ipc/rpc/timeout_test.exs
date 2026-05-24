defmodule Ourocode.IPC.RPC.TimeoutTest do
  use ExUnit.Case, async: true

  alias Ourocode.IPC.RPC.Timeout

  test "normalize accepts positive integers and infinity" do
    assert Timeout.normalize(:infinity) == {:ok, :infinity}
    assert Timeout.normalize(50) == {:ok, 50}
  end

  test "normalize rejects invalid timeout values" do
    assert Timeout.normalize(0) == {:error, {:invalid_timeout, 0}}
    assert Timeout.normalize(-1) == {:error, {:invalid_timeout, -1}}
    assert Timeout.normalize("100") == {:error, {:invalid_timeout, "100"}}
  end

  test "call_timeout adds GenServer slack unless timeout is infinity" do
    assert Timeout.call_timeout(:infinity) == :infinity
    assert Timeout.call_timeout(50) == 1_050
  end

  test "schedule returns nil for infinity and emits request timeout messages" do
    assert Timeout.schedule("req-never", :infinity) == nil

    timer = Timeout.schedule("req-now", 1)
    assert is_reference(timer)
    assert_receive {:request_timeout, "req-now"}, 100
  end

  test "cancel handles nil and timer references" do
    assert Timeout.cancel(nil) == :ok

    timer = Timeout.schedule("req-cancel", 100)
    cancelled = Timeout.cancel(timer)
    assert cancelled == false or is_integer(cancelled)
    refute_receive {:request_timeout, "req-cancel"}, 150
  end
end
