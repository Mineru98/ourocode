defmodule Ourocode.Terminal.TuiChatTest do
  # async: false — the persistence test points OUROCODE_STATE_DIR at a tmp dir.
  use ExUnit.Case, async: false

  alias Ourocode.Model
  alias Ourocode.Model.Conversation
  alias Ourocode.Terminal.{TuiChat, TuiState}

  test "chat threads the conversation into the model and stores the completed turn" do
    state = TuiState.start_link()
    # The state agent is linked to the test process and dies with it.
    {:ok, output} = StringIO.open("")
    parent = self()

    model = %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn prompt, opts, on_chunk ->
        send(parent, {:ran, prompt, Keyword.get(opts, :history)})
        on_chunk.("pong")
        {:ok, "pong"}
      end
    }

    redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end

    TuiChat.chat("ping", %{}, output, state, 80, 24, fn _state -> model end, redraw)

    assert_received {:ran, "ping", %Conversation{turns: []}}
    assert TuiState.conversation(state).turns == [%{user: "ping", assistant: "pong"}]

    # The second turn receives the first exchange as history.
    TuiChat.chat("again", %{}, output, state, 80, 24, fn _state -> model end, redraw)

    assert_received {:ran, "again", %Conversation{turns: [%{user: "ping", assistant: "pong"}]}}

    TuiState.clear_conversation(state)
    assert Conversation.empty?(TuiState.conversation(state))
  end

  test "the conversation survives a TUI restart for the same project" do
    state_dir =
      Path.join(System.tmp_dir!(), "ourocode-chat-persist-#{System.unique_integer([:positive])}")

    File.mkdir_p!(state_dir)
    original = System.get_env("OUROCODE_STATE_DIR")
    System.put_env("OUROCODE_STATE_DIR", state_dir)

    on_exit(fn ->
      if original,
        do: System.put_env("OUROCODE_STATE_DIR", original),
        else: System.delete_env("OUROCODE_STATE_DIR")

      File.rm_rf(state_dir)
    end)

    result = %{context: %{project_dir: "/tmp/persist-project"}}
    parent = self()

    model = %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn _prompt, opts, on_chunk ->
        send(parent, {:history, Keyword.get(opts, :history)})
        on_chunk.("pong")
        {:ok, "pong"}
      end
    }

    redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end

    # First run: one exchange, persisted on completion.
    first_state = TuiState.start_link()
    {:ok, first_output} = StringIO.open("")
    TuiChat.chat("ping", result, first_output, first_state, 80, 24, fn _state -> model end, redraw)
    assert_received {:history, %Conversation{turns: []}}
    Agent.stop(first_state)

    # Second run (fresh TuiState = restarted TUI): history is restored.
    second_state = TuiState.start_link()
    {:ok, second_output} = StringIO.open("")

    TuiChat.chat(
      "again",
      result,
      second_output,
      second_state,
      80,
      24,
      fn _state -> model end,
      redraw
    )

    assert_received {:history, %Conversation{turns: [%{user: "ping", assistant: "pong"}]}}
  end

  test "a failed turn leaves the conversation unchanged" do
    state = TuiState.start_link()
    # The state agent is linked to the test process and dies with it.
    {:ok, output} = StringIO.open("")

    model = %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn _prompt, _opts, _on_chunk -> {:error, :timeout} end
    }

    redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end
    TuiChat.chat("ping", %{}, output, state, 80, 24, fn _state -> model end, redraw)

    assert Conversation.empty?(TuiState.conversation(state))
  end
end
