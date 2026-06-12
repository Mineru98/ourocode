defmodule Ourocode.Terminal.TuiLoginTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.TuiLogin

  test "transient_poll_error? keeps polling on transport errors and retryable statuses" do
    assert TuiLogin.transient_poll_error?({:http_error, :timeout})
    assert TuiLogin.transient_poll_error?({:http_error, {:failed_connect, []}})
    assert TuiLogin.transient_poll_error?({:device_poll_failed, 408, %{}})
    assert TuiLogin.transient_poll_error?({:device_poll_failed, 429, %{}})
    assert TuiLogin.transient_poll_error?({:device_poll_failed, 500, %{}})
    assert TuiLogin.transient_poll_error?({:device_poll_failed, 503, %{}})
  end

  test "transient_poll_error? aborts on definitive 4xx poll failures" do
    refute TuiLogin.transient_poll_error?({:device_poll_failed, 400, %{}})
    refute TuiLogin.transient_poll_error?({:device_poll_failed, 410, %{}})
    refute TuiLogin.transient_poll_error?({:device_poll_failed, 422, %{}})
  end
end
