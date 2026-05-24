defmodule Ourocode.Terminal.EventLoopInputTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.EventLoopInput

  test "normalize converts EOF values" do
    assert EventLoopInput.normalize(:eof) == :eof
    assert EventLoopInput.normalize(nil) == :eof
  end

  test "normalize trims terminal line endings" do
    assert EventLoopInput.normalize("hello\n") == {:line, "hello"}
    assert EventLoopInput.normalize("hello\r\n") == {:line, "hello"}
  end

  test "normalize converts keyboard values" do
    assert EventLoopInput.normalize(%{key: :tab}) == {:keyboard, %{key: :tab}}
    assert EventLoopInput.normalize({:key, :tab}) == {:keyboard, %{key: :tab}}
  end

  test "normalize rejects unknown raw input" do
    assert EventLoopInput.normalize({:mouse, :click}) ==
             {:error, {:invalid_terminal_input, {:mouse, :click}}}
  end

  test "read invokes state read_line with prompt" do
    parent = self()

    state = %{
      prompt: "ourocode> ",
      read_line: fn prompt ->
        send(parent, {:read, prompt})
        "queued work\n"
      end
    }

    assert EventLoopInput.read(state) == {:line, "queued work"}
    assert_receive {:read, "ourocode> "}
  end
end
