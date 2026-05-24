defmodule Ourocode.Terminal.EventLoopLineFlowTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.{Registry, RegistryEntryAdapter}
  alias Ourocode.Runtime.FocusState
  alias Ourocode.Terminal.EventLoopLineFlow
  alias Ourocode.Terminal.FocusNavigation

  test "dispatch increments iteration for empty input" do
    {:ok, state} = EventLoopLineFlow.dispatch("", state())

    assert state.iterations == 1
  end

  test "dispatch returns shutdown for configured exit signals" do
    {:ok, output} = StringIO.open("")

    assert {:shutdown, "/quit", state} =
             EventLoopLineFlow.dispatch("/quit", state(output: output, exit_signals: ["/quit"]))

    assert state.iterations == 1

    {_input, text} = StringIO.contents(output)
    assert text =~ "exiting ourocode"
  end

  test "dispatch routes slash commands through command dispatch" do
    parent = self()

    {:ok, state} =
      EventLoopLineFlow.dispatch(
        "/clear",
        state(
          on_command: fn command_event, args, startup_result, loop_state ->
            send(parent, {:command, command_event, args, startup_result, loop_state.iterations})
            :ok
          end
        )
      )

    assert state.iterations == 1
    assert [%{command: "/clear"}] = state.command_events

    assert_receive {:command, %{command: "/clear"}, [], %{status: :healthy}, 0}
  end

  test "dispatch records command errors and accepts the next prompt" do
    parent = self()
    {:ok, output} = StringIO.open("")

    state =
      state(
        output: output,
        on_command: fn command_event, args, startup_result, loop_state ->
          send(parent, {:command, command_event, args, startup_result, loop_state.iterations})
          {:error, {:unknown_pane, hd(args)}}
        end,
        on_command_error: fn command_error, command_event, startup_result ->
          send(parent, {:command_error, command_error, command_event, startup_result})
        end,
        on_prompt_input: fn task_request, input_event, startup_result ->
          send(parent, {:prompt, task_request, input_event, startup_result})
          {:ok, task_request}
        end
      )

    assert {:ok, state} = EventLoopLineFlow.dispatch("/pane missing-child", state)
    assert {:ok, state} = EventLoopLineFlow.dispatch("Recover after command error", state)

    assert state.iterations == 2
    assert [%{command: "/pane", args: ["missing-child"]}] = state.command_events
    assert [%{type: :slash_command_failed, command: "/pane"}] = state.command_errors
    assert [%{task_input: "Recover after command error"}] = state.submitted_tasks

    assert_receive {:command, %{command: "/pane"}, ["missing-child"], %{status: :healthy}, 0}

    assert_receive {:command_error, %{reason: {:unknown_pane, "missing-child"}},
                    %{command: "/pane"}, %{status: :healthy}}

    assert_receive {:prompt, %{task_input: "Recover after command error"},
                    %{task_input: "Recover after command error"}, %{status: :healthy}}

    {_input, text} = StringIO.contents(output)
    assert text =~ "command /pane failed: {:unknown_pane, \"missing-child\"}"
  end

  test "dispatch routes natural language through task submission" do
    parent = self()

    {:ok, state} =
      EventLoopLineFlow.dispatch(
        "inspect the runtime",
        state(
          on_prompt_input: fn task_request, input_event, startup_result ->
            send(parent, {:prompt, task_request, input_event, startup_result})
            {:ok, task_request}
          end
        )
      )

    assert state.iterations == 1
    assert [%{task_input: "inspect the runtime"}] = state.submitted_tasks

    assert_receive {:prompt, %{task_input: "inspect the runtime"},
                    %{task_input: "inspect the runtime"}, %{status: :healthy}}
  end

  test "dispatch keeps bare ooo prefix on the workflow prompt path" do
    parent = self()

    {:ok, state} =
      EventLoopLineFlow.dispatch(
        "ooo build a seed",
        state(
          on_prompt_input: fn task_request, input_event, startup_result ->
            send(parent, {:prompt, task_request, input_event, startup_result})
            {:ok, task_request}
          end
        )
      )

    assert state.iterations == 1
    assert state.command_events == []
    assert [%{task_input: "ooo build a seed"}] = state.submitted_tasks

    assert_receive {:prompt, %{routing_decision: %{execution_route: :ouroboros_workflow}},
                    %{task_input: "ooo build a seed"}, %{status: :healthy}}
  end

  test "dispatch opens palette from the merged command registry" do
    {:ok, registry} = Registry.load_builtin()
    skill = local_skill_entry()
    assert {:ok, registry} = Registry.merge_normalized_entries(registry, skill)

    {:ok, output} = StringIO.open("")

    {:ok, state} =
      EventLoopLineFlow.dispatch(
        "/",
        state(output: output, startup_result: %{status: :healthy, commands: registry})
      )

    assert state.iterations == 1
    assert [%{registry: %{entries: entries}}] = state.command_palette_events
    assert Enum.any?(entries, &(&1.slash == "/ship-it" and &1.source == :local))

    {_input, text} = StringIO.contents(output)
    assert text =~ "+-- Command Palette"
    assert text =~ "| /help [builtin/discovery]"
    assert text =~ ~s(| /ship-it [local/skills] summary="Run the local ship workflow.")
  end

  defp state(attrs \\ []) do
    output =
      case Keyword.fetch(attrs, :output) do
        {:ok, output} ->
          output

        :error ->
          {:ok, output} = StringIO.open("")
          output
      end

    build_state(attrs, output)
  end

  defp build_state(attrs, output) do
    defaults = %{
      active_command_palette: nil,
      accepted_input_buffer: [],
      command_errors: [],
      command_events: [],
      command_palette_events: [],
      exit_signals: ["/exit"],
      focus_events: [],
      focus_state: FocusState.new(),
      input_events: [],
      iterations: 0,
      journal_path: nil,
      on_command: fn _command_event, _args, _startup_result, _state -> :ok end,
      on_command_error: fn _error, _command_event, _startup_result -> :ok end,
      on_command_palette: fn _event, _startup_result -> :ok end,
      on_command_palette_selection: fn _event, _startup_result -> :ok end,
      on_input_event: fn _input_event, _startup_result -> :ok end,
      on_prompt_input: fn task_request, _startup_result -> {:ok, task_request} end,
      on_prompt_state_change: fn _event, _startup_result -> :ok end,
      output: output,
      pane_model: FocusNavigation.default_pane_model(),
      prompt_state: :awaiting_prompt,
      prompt_state_events: [],
      recoverable_errors: [],
      startup_result: %{status: :healthy},
      submitted_tasks: []
    }

    Map.merge(defaults, Map.new(attrs))
  end

  defp local_skill_entry do
    RegistryEntryAdapter.from_skill_definition!(
      %{
        "id" => "ship-it",
        "name" => "Ship It",
        "description" => "Run the local ship workflow."
      },
      id: "local_skill:ship-it",
      source: :local,
      source_id: "/tmp/local-skills",
      distribution: :local,
      run_kind: :local_skill
    )
  end
end
