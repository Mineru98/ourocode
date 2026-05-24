defmodule Ourocode.Terminal.EventLoopTaskSubmissionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.EventLoopState
  alias Ourocode.Terminal.EventLoopTaskSubmission
  alias Ourocode.Journal

  test "accepts journals dispatches and records a natural-language task" do
    parent = self()
    {:ok, output} = StringIO.open("")
    journal_path = journal_path("task-submission-natural-language")

    state =
      EventLoopState.build(
        %{status: :healthy},
        %{
          journal_path: journal_path,
          output: output,
          on_input_event: fn input_event, startup_result ->
            send(parent, {:input_event, input_event, startup_result})
          end,
          on_prompt_state_change: fn state_event, startup_result ->
            send(parent, {:prompt_state, state_event, startup_result})
          end,
          on_prompt_input: fn task_request, input_event, startup_result ->
            send(parent, {:prompt_input, task_request, input_event, startup_result})
          end
        },
        "ourocode> "
      )

    assert {:ok, state} = EventLoopTaskSubmission.submit("Inspect panes", state)

    assert state.iterations == 1
    assert [%{task_input: "Inspect panes"}] = state.submitted_tasks

    assert [
             %{
               type: :prompt_input_submitted,
               event_type: :prompt_input_submitted,
               source: :terminal_prompt,
               input_kind: :natural_language,
               task_input: "Inspect panes",
               routing_decision: %{requires_command_syntax?: false}
             } = input_event
           ] = state.input_events

    assert state.prompt_state == :awaiting_prompt
    assert input_event.task_request_id == hd(state.submitted_tasks).id
    assert is_integer(input_event.occurred_at_ms)

    prompt_state_events = Enum.reverse(state.prompt_state_events)

    assert Enum.map(prompt_state_events, & &1.prompt_state) == [
             :dispatching_input,
             :awaiting_prompt
           ]

    assert Enum.map(prompt_state_events, & &1.reason) == [
             :input_dispatch_started,
             :input_dispatch_completed
           ]

    assert Enum.all?(
             prompt_state_events,
             &(&1.task_request_id == input_event.task_request_id)
           )

    assert_receive {:input_event, ^input_event, %{status: :healthy}}
    assert_receive {:prompt_state, %{prompt_state: :dispatching_input}, %{status: :healthy}}
    assert_receive {:prompt_state, %{prompt_state: :awaiting_prompt}, %{status: :healthy}}

    assert_receive {:prompt_input, %{task_input: "Inspect panes"}, _input_event,
                    %{status: :healthy}}

    {_input, output_text} = StringIO.contents(output)
    assert output_text =~ "Parent Workflow"
    assert output_text =~ "queued task"

    assert {:ok, [journaled]} = Journal.read_ordered(journal_path)
    assert journaled.type == :prompt_input_submitted
    assert journaled.source == :terminal_prompt
    assert journaled.input_kind == :natural_language
    assert journaled.task_input == "Inspect panes"
  end

  test "invalid prompt input is ignored and increments iterations" do
    {:ok, output} = StringIO.open("")

    state =
      EventLoopState.build(
        %{status: :healthy},
        %{output: output},
        "ourocode> "
      )

    assert {:ok, state} = EventLoopTaskSubmission.submit("", state)
    assert state.iterations == 1
    assert state.submitted_tasks == []
    assert state.input_events == []

    {_input, output_text} = StringIO.contents(output)
    assert output_text =~ "ignored input"
  end

  test "accepted prompt events keep journal sequences and buffer identity" do
    parent = self()
    journal_path = journal_path("task-submission-accepted-sequence")
    {:ok, output} = StringIO.open("")

    state =
      EventLoopState.build(
        %{status: :healthy},
        %{
          journal_path: journal_path,
          output: output,
          on_prompt_input: fn _task_request, input_event, _startup_result ->
            send(parent, {:accepted_input_event, input_event})
            :ok
          end
        },
        "ourocode> "
      )

    assert {:ok, state} = EventLoopTaskSubmission.submit("Repeat this prompt exactly", state)
    assert {:ok, state} = EventLoopTaskSubmission.submit("Repeat this prompt exactly", state)
    assert {:ok, state} = EventLoopTaskSubmission.submit("Then preserve the third prompt", state)

    input_events = Enum.reverse(state.input_events)
    accepted_input_buffer = Enum.reverse(state.accepted_input_buffer)

    assert Enum.map(input_events, & &1.event_seq) == [1, 2, 3]
    assert Enum.map(accepted_input_buffer, & &1.event_seq) == [1, 2, 3]

    assert Enum.map(accepted_input_buffer, & &1.task_request_id) ==
             Enum.map(input_events, & &1.task_request_id)

    assert Enum.map(accepted_input_buffer, & &1.task_input) == [
             "Repeat this prompt exactly",
             "Repeat this prompt exactly",
             "Then preserve the third prompt"
           ]

    assert_receive {:accepted_input_event,
                    %{task_input: "Repeat this prompt exactly", event_seq: 1}}

    assert_receive {:accepted_input_event,
                    %{task_input: "Repeat this prompt exactly", event_seq: 2}}

    assert_receive {:accepted_input_event,
                    %{task_input: "Then preserve the third prompt", event_seq: 3}}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, & &1.type) == [
             :prompt_input_submitted,
             :prompt_input_submitted,
             :prompt_input_submitted
           ]

    assert Enum.map(journaled, & &1.event_seq) == [1, 2, 3]

    assert Enum.map(journaled, & &1.task_input) == [
             "Repeat this prompt exactly",
             "Repeat this prompt exactly",
             "Then preserve the third prompt"
           ]
  end

  defp journal_path(name) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")

    File.rm(path)
    path
  end
end
