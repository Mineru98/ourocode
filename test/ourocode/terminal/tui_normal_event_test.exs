defmodule Ourocode.Terminal.TuiNormalEventTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiNormalEvent, TuiState}

  setup do
    state = TuiState.start_link()
    Agent.update(state, &%{&1 | buffer: "", cursor: 0, mode: :normal, pidx: 0})

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    %{state: state}
  end

  test "ctrl-d exits only when the composer is empty", %{state: state} do
    assert TuiNormalEvent.handle(%{key: :ctrl_d}, state, callbacks()) == :exit

    TuiState.edit_buffer(state, %{key: :char, char: "x"})

    assert TuiNormalEvent.handle(%{key: :ctrl_d}, state, callbacks()) == :continue
    assert TuiState.buffer(state) == "x"
  end

  test "char input edits buffer and redraws", %{state: state} do
    parent = self()

    assert TuiNormalEvent.handle(%{key: :char, char: "a"}, state, callbacks(parent)) ==
             :continue

    assert TuiState.buffer(state) == "a"
    assert_received :draw
  end

  test "enter submits trimmed buffer, clears composer, and remembers history", %{state: state} do
    parent = self()
    TuiState.edit_buffer(state, %{key: :paste, char: "  hello  "})

    assert TuiNormalEvent.handle(%{key: :enter}, state, callbacks(parent)) == :continue

    assert TuiState.buffer(state) == ""
    assert_received {:entered, "hello"}

    TuiState.move_history(state, -1)
    assert TuiState.buffer(state) == "hello"
  end

  test "page keys adjust scroll and redraw", %{state: state} do
    parent = self()

    assert TuiNormalEvent.handle(%{key: :page_up}, state, callbacks(parent)) == :continue
    assert_received :draw

    assert TuiNormalEvent.handle(%{key: :page_down}, state, callbacks(parent)) == :continue
    assert_received :draw
  end

  test "j and k edit the composer when workspace is active", %{state: state} do
    parent = self()

    TuiState.put_workspace(state, workspace())

    assert TuiNormalEvent.handle(%{key: :char, char: "j"}, state, callbacks(parent)) ==
             :continue

    assert get_in(TuiState.workspace(state), [:detail, :title]) == "First"
    assert TuiState.buffer(state) == "j"
    assert_received :draw

    assert TuiNormalEvent.handle(%{key: :char, char: "k"}, state, callbacks(parent)) ==
             :continue

    assert get_in(TuiState.workspace(state), [:detail, :title]) == "First"
    assert TuiState.buffer(state) == "jk"
    assert_received :draw
  end

  test "j edits the composer when workspace is active but input is not empty", %{state: state} do
    parent = self()

    TuiState.put_workspace(state, workspace())
    TuiState.edit_buffer(state, %{key: :char, char: "x"})

    assert TuiNormalEvent.handle(%{key: :char, char: "j"}, state, callbacks(parent)) ==
             :continue

    assert TuiState.buffer(state) == "xj"
    assert get_in(TuiState.workspace(state), [:detail, :title]) == "First"
    assert_received :draw
  end

  test "workspace shortcut letters edit when composer is empty", %{state: state} do
    parent = self()

    TuiState.put_workspace(state, workspace())

    assert TuiNormalEvent.handle(%{key: :char, char: "v"}, state, callbacks(parent)) ==
             :continue

    assert TuiState.buffer(state) == "v"
    refute_received {:entered, "/verify"}
    assert_received :draw
  end

  test "workspace placeholder shortcut letters edit when composer is empty", %{state: state} do
    parent = self()

    TuiState.put_workspace(state, placeholder_workspace())

    assert TuiNormalEvent.handle(%{key: :char, char: "p"}, state, callbacks(parent)) ==
             :continue

    assert TuiState.buffer(state) == "p"
    assert_received :draw
    refute_received {:entered, _line}
  end

  test "workspace shortcut key edits when composer is not empty", %{state: state} do
    parent = self()

    TuiState.put_workspace(state, workspace())
    TuiState.edit_buffer(state, %{key: :char, char: "x"})

    assert TuiNormalEvent.handle(%{key: :char, char: "v"}, state, callbacks(parent)) ==
             :continue

    assert TuiState.buffer(state) == "xv"
    refute_received {:entered, "/verify"}
    assert_received :draw
  end

  test "workspace resume shortcut letters edit when composer is empty", %{state: state} do
    parent = self()

    TuiState.put_workspace(state, resume_workspace())

    assert TuiNormalEvent.handle(%{key: :char, char: "l"}, state, callbacks(parent)) ==
             :continue

    assert TuiState.buffer(state) == "l"
    refute_received {:entered, "/resume latest"}
    assert_received :draw
  end

  test "slash stays in composer during interview capture", %{state: state} do
    parent = self()

    assert TuiNormalEvent.handle(
             %{key: :char, char: "/"},
             state,
             callbacks(parent, %{interview_capturing?: true})
           ) == :continue

    assert TuiState.mode(state) == :normal
    assert TuiState.buffer(state) == "/"
    refute_received :draw
  end

  test "cancel prefix during interview capture submits as soon as complete without redraws", %{
    state: state
  } do
    parent = self()
    callbacks = callbacks(parent, %{interview_capturing?: true})

    Enum.each(String.graphemes("/cance"), fn char ->
      assert TuiNormalEvent.handle(%{key: :char, char: char}, state, callbacks) == :continue
    end)

    assert TuiState.buffer(state) == "/cance"
    refute_received :draw
    refute_received {:entered, _line}

    assert TuiNormalEvent.handle(%{key: :char, char: "l"}, state, callbacks) == :continue
    assert_received {:entered, "/cancel"}
    assert TuiState.buffer(state) == ""
    refute_received :draw
  end

  test "completed cancel prefix clears buffer so a following enter cannot dispatch it again", %{
    state: state
  } do
    parent = self()
    callbacks = callbacks(parent, %{interview_capturing?: true})

    for char <- String.graphemes("/cancel") do
      assert TuiNormalEvent.handle(%{key: :char, char: char}, state, callbacks) == :continue
    end

    assert_received {:entered, "/cancel"}
    assert TuiState.buffer(state) == ""

    assert TuiNormalEvent.handle(%{key: :enter}, state, callbacks) == :continue

    refute_received {:entered, "/cancel"}
  end

  defp callbacks(parent \\ self(), extra \\ %{}) do
    Map.merge(
      %{
        choose_model: fn -> send(parent, :choose_model) end,
        cont: fn -> :continue end,
        draw: fn -> send(parent, :draw) end,
        handle_enter: fn line ->
          send(parent, {:entered, line})
          :continue
        end,
        test_run?: fn -> true end
      },
      extra
    )
  end

  defp workspace do
    first = %{id: "record:first", title: "First", actions: [%{command: "/first", enabled: true}]}

    second = %{
      id: "record:second",
      title: "Second",
      actions: [%{command: "/second", enabled: true}]
    }

    %{
      kind: "test",
      selected: "record:first",
      records: [first, second],
      detail: first,
      actions: [%{id: "verify", shortcut: "v", command: "/verify", enabled: true}]
    }
  end

  defp placeholder_workspace do
    first = %{id: "record:first", title: "First", actions: [%{command: "/first", enabled: true}]}

    %{
      kind: "test",
      selected: "record:first",
      records: [first],
      detail: first,
      actions: [%{id: "preflight", shortcut: "p", command: "/preflight <command>", enabled: true}]
    }
  end

  defp resume_workspace do
    first = %{
      id: "session:1",
      title: "Headless command",
      actions: [%{command: "/resume 1", enabled: true}]
    }

    %{
      kind: "resume",
      selected: "session:1",
      records: [first],
      detail: first,
      actions: [%{id: "resume_latest", shortcut: "l", command: "/resume latest", enabled: true}]
    }
  end
end
