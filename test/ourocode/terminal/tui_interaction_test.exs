defmodule Ourocode.Terminal.TuiInteractionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiInteraction, TuiState}

  setup do
    {:ok, output} = StringIO.open("")
    state = TuiState.start_link()
    Agent.update(state, &%{&1 | buffer: "", cursor: 0, wonder_nav: nil})

    on_exit(fn ->
      safe_close(output, &StringIO.close/1)
      safe_close(state, &Agent.stop/1)
    end)

    %{output: output, state: state}
  end

  test "slash answer submits free text to the active wonder question", %{
    output: output,
    state: state
  } do
    parent = self()
    TuiState.put_wonder_nav(state, %{qidx: 1, picks: %{1 => 0}})

    result =
      wonder_result(fn payload ->
        send(parent, {:payload, payload})
        {:ok, %{selected_label: "custom"}}
      end)

    assert :ok = TuiInteraction.submit_slash_answer("custom", result, output, state)
    assert_received {:payload, %{"freeText" => "custom", "questionId" => "second"}}

    {_input, captured} = StringIO.contents(output)
    assert captured =~ "you> custom"
  end

  test "empty enter on multi-question wonder asks for review before submitting", %{
    output: output,
    state: state
  } do
    parent = self()
    TuiState.put_wonder_nav(state, %{qidx: 0, picks: %{0 => 0, 1 => 0}})

    result =
      wonder_result(fn payload ->
        send(parent, {:submitted, payload})
        {:ok, %{selected_label: "submitted"}}
      end)

    assert :ok = TuiInteraction.handle_event(%{key: :enter}, result, output, state)
    assert TuiState.wonder_nav(state).review?
    refute_received {:submitted, _payload}

    assert :ok = TuiInteraction.handle_event(%{key: :enter}, result, output, state)
    assert_received {:submitted, [1, 1]}
  end

  test "escape invokes wonder pause callback", %{output: output, state: state} do
    parent = self()

    result =
      Map.put(wonder_result(fn _payload -> {:ok, %{}} end), :wonder_pause, fn ->
        send(parent, :paused)
      end)

    assert :ok = TuiInteraction.handle_event(%{key: :escape}, result, output, state)
    assert_received :paused

    {_input, captured} = StringIO.contents(output)
    assert captured =~ "-- interview paused"
  end

  defp wonder_result(answer_fun) do
    %{
      pane_snapshot: fn -> %{wonder_tool: detection(), paused: false} end,
      wonder_answer: answer_fun
    }
  end

  defp detection do
    %{
      request: %{
        tool: :wonder_tool,
        type: :multiple_choice_decision,
        questions: [
          %{id: "first", header: "First", question: "Pick one", options: [opt("a")]},
          %{id: "second", header: "Second", question: "Explain", options: [opt("b")]}
        ]
      }
    }
  end

  defp opt(label), do: %{label: label, description: "#{label} description"}

  defp safe_close(pid, close) when is_pid(pid) and is_function(close, 1) do
    if Process.alive?(pid), do: close.(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
