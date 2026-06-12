defmodule Ourocode.Terminal.TuiLoginTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiLogin, TuiState}

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

  test "claude login arms a pending paste step with a claude.ai authorize URL" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")
    redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end

    TuiLogin.start(:claude_api, %{}, output, state, 80, 24, redraw)

    pending = TuiState.pending_login(state)
    assert pending.provider == :claude_api
    assert is_binary(pending.verifier) and pending.verifier != ""
    assert is_binary(pending.state) and pending.state != ""

    {_in, text} = StringIO.contents(output)
    assert text =~ "https://claude.ai/oauth/authorize"
    assert text =~ "paste the authorization code"
  end

  test "complete_paste is a no-op when no login is pending" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    assert TuiLogin.complete_paste("hello there", output, state) == :not_pending
  end
end
