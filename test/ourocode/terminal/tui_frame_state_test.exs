defmodule Ourocode.Terminal.TuiFrameStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiFrame, TuiState}

  test "view_opts projects mutable TUI state into renderer options" do
    state = TuiState.start_link()

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    TuiState.put_mode(state, :palette)
    TuiState.put_pidx(state, 2)
    TuiState.toggle_key_help(state)
    TuiState.set_streaming(state, true)

    opts =
      TuiFrame.view_opts(state,
        auth_label: fn ^state -> "gpt-5" end,
        test_run?: fn -> true end
      )

    assert opts.mode == :palette
    assert opts.auth == "gpt-5"
    assert opts.streaming == true
    assert opts.key_help == true
    assert opts.pidx == 2
    assert is_map(opts.palette)
    assert opts.model == nil
    assert is_list(opts.file_mentions)
  end
end
