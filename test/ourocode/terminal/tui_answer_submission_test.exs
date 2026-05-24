defmodule Ourocode.Terminal.TuiAnswerSubmissionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiAnswerSubmission, TuiState}

  setup do
    {:ok, output} = StringIO.open("")
    state = TuiState.start_link()
    Agent.update(state, &%{&1 | buffer: "", cursor: 0, wonder_nav: %{qidx: 0, picks: %{0 => 0}}})

    on_exit(fn ->
      safe_close(output, &StringIO.close/1)
      safe_close(state, &Agent.stop/1)
    end)

    %{output: output, state: state}
  end

  test "submit_enter_answer cancels active wonder checkpoints", %{output: output, state: state} do
    parent = self()

    result =
      wonder_result(
        fn _payload -> {:ok, %{}} end,
        fn answer ->
          send(parent, {:cancelled, answer})
          {:ok, %{cancelled: true}}
        end
      )

    assert :handled =
             TuiAnswerSubmission.submit_enter_answer(
               "cancel",
               result,
               output,
               state,
               wonder_context()
             )

    assert_received {:cancelled, "cancel"}
    {_input, captured} = StringIO.contents(output)
    assert captured =~ "you> cancel"
  end

  test "submit_enter_answer sends wonder free text", %{output: output, state: state} do
    parent = self()

    result =
      wonder_result(fn payload ->
        send(parent, {:payload, payload})
        {:ok, %{selected_label: "custom"}}
      end)

    assert :handled =
             TuiAnswerSubmission.submit_enter_answer(
               "custom",
               result,
               output,
               state,
               wonder_context()
             )

    assert_received {:payload, %{"freeText" => "custom", "questionId" => "first"}}
  end

  test "submit_free_text sends interview answer", %{output: output, state: state} do
    parent = self()

    result = %{
      interview_answer: fn answer ->
        send(parent, {:interview, answer})
        {:ok, answer}
      end
    }

    assert :ok =
             TuiAnswerSubmission.submit_free_text(
               "interview answer",
               result,
               output,
               state,
               %{wonder_active?: false, wonder_detection: nil, interview_active?: true}
             )

    assert_received {:interview, "interview answer"}
    {_input, captured} = StringIO.contents(output)
    assert captured =~ "you> interview answer"
  end

  test "submit_enter_answer returns not_handled for empty answers", %{
    output: output,
    state: state
  } do
    assert :not_handled =
             TuiAnswerSubmission.submit_enter_answer(
               "",
               %{},
               output,
               state,
               %{wonder_active?: true, wonder_detection: detection(), interview_active?: false}
             )
  end

  defp wonder_result(answer_fun, cancel_fun \\ nil) do
    result = %{wonder_answer: answer_fun}
    if cancel_fun, do: Map.put(result, :wonder_cancel, cancel_fun), else: result
  end

  defp wonder_context do
    %{wonder_active?: true, wonder_detection: detection(), interview_active?: false}
  end

  defp detection do
    %{
      request: %{
        tool: :wonder_tool,
        type: :multiple_choice_decision,
        questions: [
          %{id: "first", header: "First", question: "Pick one", options: [opt("a")]}
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
