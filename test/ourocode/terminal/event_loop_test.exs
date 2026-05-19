defmodule Ourocode.Terminal.EventLoopTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.{Registry, RegistryEntryAdapter}
  alias Ourocode.Terminal.EventLoop
  alias Ourocode.Terminal.NetworkListenerGuard
  alias Ourocode.{Journal, Json}

  import ExUnit.CaptureIO

  test "core prompt loop uses terminal IO devices without starting local listener surfaces" do
    parent = self()

    assert {:ok, before_guard} =
             NetworkListenerGuard.verify_startup_boundary(stage: :before_prompt_loop_io_test)

    {:ok, input} = StringIO.open("Inspect parent and child panes\n/exit\n")
    {:ok, output} = StringIO.open("")

    assert {:ok, result} =
             EventLoop.run(%{status: :healthy}, %{
               input: input,
               output: output,
               prompt: "ourocode> ",
               on_task: fn task_request, startup_result ->
                 send(parent, {:task_request, task_request, startup_result})
                 :ok
               end
             })

    assert {:ok, after_guard} =
             NetworkListenerGuard.verify_startup_boundary(stage: :after_prompt_loop_io_test)

    assert before_guard.started_listener_apps == []
    assert before_guard.registered_listener_processes == []
    assert before_guard.startup_source_listener_calls == []
    assert after_guard.started_listener_apps == []
    assert after_guard.registered_listener_processes == []
    assert after_guard.startup_source_listener_calls == []

    assert result.status == :exit_signal_received
    assert result.exit_signal == "/exit"
    assert result.iterations == 2

    assert Enum.map(result.submitted_tasks, & &1.task_input) == [
             "Inspect parent and child panes"
           ]

    assert Enum.map(result.input_events, & &1.input_kind) == [:natural_language]

    assert_receive {:task_request, %{task_input: "Inspect parent and child panes"},
                    %{status: :healthy}}

    {_input_text, output_text} = StringIO.contents(output)
    assert output_text =~ "queued task"
    assert output_text =~ "exiting ourocode"
  end

  test "keeps reading natural-language prompts until an explicit exit signal" do
    parent = self()
    lines = start_lines(["Inspect parent panes\n", "Route this to child\n", "/exit\n"])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(%{status: :healthy}, %{
                   read_line: next_line(lines),
                   on_task: fn task_request, startup_result ->
                     send(parent, {:task_request, task_request, startup_result})
                   end
                 })

        assert result.status == :exit_signal_received
        assert result.exit_signal == "/exit"
        assert result.iterations == 3

        assert Enum.map(result.submitted_tasks, & &1.task_input) == [
                 "Inspect parent panes",
                 "Route this to child"
               ]

        assert Enum.map(result.input_events, & &1.task_input) == [
                 "Inspect parent panes",
                 "Route this to child"
               ]
      end)

    assert_receive {:task_request, %{task_input: "Inspect parent panes"}, %{status: :healthy}}
    assert_receive {:task_request, %{task_input: "Route this to child"}, %{status: :healthy}}
    assert output =~ "queued task"
    assert output =~ "exiting ourocode"
  end

  test "recognizes only exact explicit exit commands as shutdown signals" do
    assert EventLoop.shutdown_signal?("/exit")
    assert EventLoop.shutdown_signal?("  QUIT  ")
    assert EventLoop.shutdown_signal?(":q")

    refute EventLoop.shutdown_signal?("/exit now")
    refute EventLoop.shutdown_signal?("please exit after summarizing the pane")
    refute EventLoop.shutdown_signal?("quit after the child stream is replayed")
    refute EventLoop.shutdown_signal?("/quit-now")
  end

  test "recognizes configured exit signals without treating near matches as shutdown" do
    assert EventLoop.shutdown_signal?("  done  ", exit_signals: ["done"])
    assert EventLoop.shutdown_signal?("STOP", exit_signals: MapSet.new(["stop"]))

    refute EventLoop.shutdown_signal?("done after replay", exit_signals: ["done"])
    refute EventLoop.shutdown_signal?("/stop", exit_signals: ["stop"])
  end

  test "continues prompt loop for exit-like natural language and slash near matches" do
    parent = self()

    lines =
      start_lines([
        "please exit the child pane after replay\n",
        "/exit now\n",
        "quit after summarizing the queue\n",
        "done\n"
      ])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(%{status: :healthy}, %{
                   read_line: next_line(lines),
                   exit_signals: ["done"],
                   on_task: fn task_request, startup_result ->
                     send(parent, {:task_request, task_request, startup_result})
                   end,
                   on_command: fn command_event, args, startup_result ->
                     send(parent, {:command, command_event, args, startup_result})
                     :ok
                   end
                 })

        assert result.status == :exit_signal_received
        assert result.exit_signal == "done"
        assert result.iterations == 4

        assert Enum.map(result.submitted_tasks, & &1.task_input) == [
                 "please exit the child pane after replay",
                 "quit after summarizing the queue"
               ]

        assert [%{command: "/exit", args: ["now"]}] = result.command_events
      end)

    assert_receive {:task_request, %{task_input: "please exit the child pane after replay"},
                    %{status: :healthy}}

    assert_receive {:command, %{command: "/exit"}, ["now"], %{status: :healthy}}

    assert_receive {:task_request, %{task_input: "quit after summarizing the queue"},
                    %{status: :healthy}}

    assert output =~ "queued task"
    assert output =~ "exiting ourocode"
  end

  test "unknown slash commands suggest nearby registered commands" do
    lines = start_lines(["/capabilites\n", "/exit\n"])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(%{status: :healthy}, %{
                   read_line: next_line(lines)
                 })

        assert [%{command: "/capabilites"}] = result.command_events

        assert [%{reason: {:unknown_command, "/capabilites", suggestions}}] =
                 result.command_errors

        assert "/capabilities" in suggestions
      end)

    assert output =~ "command /capabilites failed"
    assert output =~ "did you mean /capabilities"
  end

  test "bare slash opens command palette without submitting or mutating prompt input" do
    parent = self()
    lines = start_lines(["/\n", "Prompt after palette\n", "/exit\n"])
    journal_path = journal_path("terminal-bare-slash-command-palette")

    startup_result = %{
      status: :healthy,
      panes: %{
        task_prompt: %{
          id: :task_prompt,
          value: "draft prompt stays intact",
          cursor_position: 23
        }
      }
    }

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(startup_result, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 on_command_palette: fn palette_event, callback_startup_result ->
                   send(parent, {:palette_opened, palette_event, callback_startup_result})
                   :ok
                 end,
                 on_command: fn command_event, _args, _startup_result ->
                   flunk("bare slash was submitted as a slash command: #{inspect(command_event)}")
                 end,
                 on_prompt_input: fn task_request, input_event, startup_result ->
                   send(parent, {:prompt_processed, task_request, input_event, startup_result})
                   :ok
                 end
               })

      assert result.status == :exit_signal_received
      assert result.iterations == 3
      assert result.command_events == []
      assert result.command_errors == []
      assert Enum.map(result.submitted_tasks, & &1.task_input) == ["Prompt after palette"]
      assert Enum.map(result.input_events, & &1.task_input) == ["Prompt after palette"]

      assert [
               %{
                 type: :command_palette_opened,
                 event_type: :command_palette_opened,
                 source: :terminal_prompt,
                 input_kind: :slash_palette_trigger,
                 action: :command_palette_open,
                 raw_input: "/",
                 submitted?: false,
                 prompt_mutated?: false,
                 registry: %{loaded_count: loaded_count}
               }
             ] = result.command_palette_events

      assert loaded_count > 0
    end)

    assert_receive {:palette_opened,
                    %{
                      action: :command_palette_open,
                      raw_input: "/",
                      submitted?: false,
                      prompt_mutated?: false
                    }, ^startup_result}

    assert_receive {:prompt_processed, %{task_input: "Prompt after palette"},
                    %{input_kind: :natural_language}, ^startup_result}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, &Map.get(&1, :type, Map.get(&1, "type"))) == [
             :command_palette_opened,
             :prompt_input_submitted
           ]

    palette_journal_event = hd(journaled)
    payload = Map.fetch!(palette_journal_event, :payload)

    assert palette_journal_event.raw_input == "/"
    assert palette_journal_event["submitted?"] == false
    assert palette_journal_event["prompt_mutated?"] == false
    assert payload["action"] == "command_palette_open"
    assert payload["raw_input"] == "/"
    assert payload["submitted?"] == false
    assert payload["prompt_mutated?"] == false
  end

  test "bare slash renders palette entries from the merged command registry" do
    {:ok, registry} = Registry.load_builtin()

    skill =
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

    assert {:ok, registry} = Registry.merge_normalized_entries(registry, skill)

    lines = start_lines(["/\n", "/exit\n"])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(%{status: :healthy, commands: registry}, %{
                   read_line: next_line(lines)
                 })

        assert [%{registry: %{entries: entries}}] = result.command_palette_events
        assert Enum.any?(entries, &(&1.slash == "/ship-it" and &1.source == :local))
      end)

    assert output =~ "+-- Command Palette"
    assert output =~ "| /help [builtin/discovery]"
    assert output =~ ~s(| /ship-it [local/skills] summary="Run the local ship workflow.")
  end

  test "palette numeric selection emits and journals the selected registry item" do
    parent = self()
    {:ok, registry} = Registry.load_builtin()

    skill =
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

    assert {:ok, registry} = Registry.merge_normalized_entries(registry, skill)

    selected_index = registry.loaded_count
    lines = start_lines(["/\n", "#{selected_index}\n", "/exit\n"])
    journal_path = journal_path("terminal-command-palette-selection")

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(%{status: :healthy, commands: registry}, %{
                   read_line: next_line(lines),
                   journal_path: journal_path,
                   on_command_palette_selection: fn selection_event, startup_result ->
                     send(parent, {:palette_selected, selection_event, startup_result})
                     :ok
                   end,
                   on_command: fn command_event, _args, _startup_result ->
                     flunk(
                       "palette selection was submitted as slash command: #{inspect(command_event)}"
                     )
                   end
                 })

        assert result.status == :exit_signal_received
        assert result.iterations == 3
        assert result.command_events == []

        assert [
                 %{type: :command_palette_opened},
                 %{
                   type: :command_palette_selected,
                   input_kind: :slash_palette_selection,
                   selection_index: ^selected_index,
                   selected_slash: "/ship-it",
                   selected_registry_item: %{slash: "/ship-it", source: :local}
                 }
               ] = result.command_palette_events
      end)

    assert output =~ "+-- Command Palette"
    assert output =~ "selected /ship-it: Run the local ship workflow."

    assert_receive {:palette_selected,
                    %{
                      type: :command_palette_selected,
                      selected_slash: "/ship-it",
                      selected_registry_item: %{run_spec: %{kind: :local_skill}}
                    }, %{status: :healthy, commands: ^registry}}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, &Map.get(&1, :type, Map.get(&1, "type"))) == [
             :command_palette_opened,
             :command_palette_selected
           ]

    selection_journal_event = List.last(journaled)
    assert selection_journal_event.selected_slash == "/ship-it"
    assert selection_journal_event.selected_registry_item["slash"] == "/ship-it"
    assert selection_journal_event.selected_registry_item["source"] == "local"

    assert selection_journal_event.payload["selected_registry_item"]["run_spec"]["kind"] ==
             "local_skill"
  end

  test "ignores empty input and continues accepting subsequent prompts" do
    parent = self()
    lines = start_lines(["\n", "   \t\n", "Recover after blank input\n", "/exit\n"])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(%{status: :healthy}, %{
                   read_line: next_line(lines),
                   on_task: fn task_request, startup_result ->
                     send(parent, {:task_request, task_request, startup_result})
                   end
                 })

        assert result.status == :exit_signal_received
        assert result.exit_signal == "/exit"
        assert result.iterations == 4

        assert Enum.map(result.submitted_tasks, & &1.task_input) == [
                 "Recover after blank input"
               ]

        assert Enum.map(result.input_events, & &1.task_input) == [
                 "Recover after blank input"
               ]
      end)

    assert_receive {:task_request, %{task_input: "Recover after blank input"},
                    %{status: :healthy}}

    refute_receive {:task_request, %{task_input: ""}, _startup_result}
    assert output =~ "queued task"
    assert output =~ "exiting ourocode"
  end

  test "emits a normalized input event for a natural-language prompt line" do
    parent = self()
    lines = start_lines(["  Inspect child stream loss\n", "/exit\n"])
    journal_path = journal_path("terminal-input-event")

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 on_input_event: fn input_event, startup_result ->
                   send(parent, {:input_event, input_event, startup_result})
                 end
               })

      assert [
               %{
                 type: :prompt_input_submitted,
                 event_type: :prompt_input_submitted,
                 source: :terminal_prompt,
                 input_kind: :natural_language,
                 task_input: "Inspect child stream loss",
                 routing_decision: %{requires_command_syntax?: false}
               } = input_event
             ] = result.input_events

      assert input_event.task_request_id == hd(result.submitted_tasks).id
      assert is_integer(input_event.occurred_at_ms)
    end)

    assert_receive {:input_event,
                    %{
                      type: :prompt_input_submitted,
                      task_input: "Inspect child stream loss"
                    }, %{status: :healthy}}

    assert {:ok, [journaled]} = Journal.read_ordered(journal_path)
    assert journaled.type == :prompt_input_submitted
    assert journaled.source == :terminal_prompt
    assert journaled.input_kind == :natural_language
    assert journaled.task_input == "Inspect child stream loss"
  end

  test "accepted prompt input events expose durable unique monotonic journal sequence ids" do
    parent = self()
    lines = start_lines(["First accepted prompt\n", "Second accepted prompt\n", "/exit\n"])
    journal_path = journal_path("terminal-accepted-input-event-seq")

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 on_prompt_input: fn _task_request, input_event, _startup_result ->
                   send(parent, {:accepted_input_event, input_event})
                   :ok
                 end
               })

      assert Enum.map(result.input_events, & &1.task_input) == [
               "First accepted prompt",
               "Second accepted prompt"
             ]

      assert Enum.map(result.input_events, & &1.event_seq) == [1, 2]
      assert result.input_events |> Enum.map(& &1.event_seq) |> Enum.uniq() == [1, 2]
    end)

    assert_receive {:accepted_input_event, %{task_input: "First accepted prompt", event_seq: 1}}

    assert_receive {:accepted_input_event, %{task_input: "Second accepted prompt", event_seq: 2}}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, & &1.type) == [
             :prompt_input_submitted,
             :prompt_input_submitted
           ]

    assert Enum.map(journaled, & &1.event_seq) == [1, 2]

    assert Enum.map(journaled, & &1.task_input) == [
             "First accepted prompt",
             "Second accepted prompt"
           ]
  end

  test "ingestion to accepted input buffer preserves every accepted prompt event sequence" do
    parent = self()

    lines =
      start_lines([
        "Repeat this prompt exactly\n",
        "Repeat this prompt exactly\n",
        "Then preserve the third prompt\n",
        "/exit\n"
      ])

    journal_path = journal_path("terminal-input-buffer-handoff")

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 on_prompt_input: fn _task_request, input_event, _startup_result ->
                   send(parent, {:accepted_input_event, input_event})
                   :ok
                 end
               })

      accepted_sequence_set = result.input_events |> Enum.map(& &1.event_seq) |> MapSet.new()

      buffered_sequence_set =
        result.accepted_input_buffer |> Enum.map(& &1.event_seq) |> MapSet.new()

      assert Enum.map(result.input_events, & &1.event_seq) == [1, 2, 3]
      assert accepted_sequence_set == buffered_sequence_set
      assert length(result.accepted_input_buffer) == length(result.input_events)

      assert Enum.map(result.accepted_input_buffer, & &1.task_request_id) ==
               Enum.map(result.input_events, & &1.task_request_id)

      assert Enum.map(result.accepted_input_buffer, & &1.task_input) == [
               "Repeat this prompt exactly",
               "Repeat this prompt exactly",
               "Then preserve the third prompt"
             ]
    end)

    assert_receive {:accepted_input_event,
                    %{task_input: "Repeat this prompt exactly", event_seq: 1}}

    assert_receive {:accepted_input_event,
                    %{task_input: "Repeat this prompt exactly", event_seq: 2}}

    assert_receive {:accepted_input_event,
                    %{task_input: "Then preserve the third prompt", event_seq: 3}}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)
    assert journaled_sequence_set = journaled |> Enum.map(& &1.event_seq) |> MapSet.new()
    assert journaled_sequence_set == MapSet.new([1, 2, 3])
  end

  test "accepts and preserves the exact mixed English and Korean natural-language prompt" do
    parent = self()
    prompt = "ooo interview로 ourocode의 MCP streamable UI 요구사항을 정리해줘."
    lines = start_lines([prompt <> "\n", "/exit\n"])
    journal_path = journal_path("terminal-mixed-language-prompt")

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 on_prompt_input: fn task_request, input_event, startup_result ->
                   send(parent, {:prompt_processed, task_request, input_event, startup_result})
                   :ok
                 end
               })

      assert [%{task_input: ^prompt} = task_request] = result.submitted_tasks

      assert [%{task_input: ^prompt, payload: %{task_input: ^prompt}} = input_event] =
               result.input_events

      assert task_request.id == input_event.task_request_id
      assert result.status == :exit_signal_received
    end)

    assert_receive {:prompt_processed, %{task_input: ^prompt},
                    %{task_input: ^prompt, payload: %{task_input: ^prompt}}, %{status: :healthy}}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)
    assert [%{type: :prompt_input_submitted, task_input: ^prompt, payload: payload}] = journaled
    assert payload["task_input"] == prompt
  end

  test "routes ooo interview prompt to the interview workflow without slash command dispatch" do
    parent = self()
    prompt = "ooo interview로 ourocode의 MCP streamable UI 요구사항을 정리해줘."
    lines = start_lines([prompt <> "\n", "/exit\n"])
    journal_path = journal_path("terminal-ooo-interview-routing")

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(%{status: :healthy}, %{
                   read_line: next_line(lines),
                   journal_path: journal_path,
                   on_prompt_input: fn task_request, input_event, startup_result ->
                     send(parent, {:prompt_routed, task_request, input_event, startup_result})
                     :ok
                   end,
                   on_command: fn command_event, _args, _startup_result ->
                     flunk(
                       "ooo interview prompt was routed as slash command: #{inspect(command_event)}"
                     )
                   end
                 })

        assert result.status == :exit_signal_received
        assert result.command_events == []

        assert [
                 %{
                   task_input: ^prompt,
                   routing_decision: %{
                     kind: :ouroboros_workflow,
                     execution_route: :ouroboros_workflow,
                     runtime_source: :ouroboros,
                     transport: :auto,
                     requires_command_syntax?: false,
                     advanced_shortcut?: true,
                     reason: :explicit_ouroboros_shortcut,
                     adapter_route: :interview
                   }
                 }
               ] = result.submitted_tasks

        assert [
                 %{
                   input_kind: :natural_language,
                   task_input: ^prompt,
                   routing_decision: %{
                     execution_route: :ouroboros_workflow,
                     adapter_route: :interview
                   }
                 }
               ] = result.input_events
      end)

    assert output =~ "+-- Parent Workflow region=parent_pane"
    assert output =~ "[workflow-starting] state=dispatching_input"
    assert output =~ "route=ouroboros_workflow adapter=interview"
    assert output =~ ~s(accepted_prompt="#{prompt}")

    assert_receive {:prompt_routed, task_request, input_event, %{status: :healthy}}
    assert task_request.routing_decision.adapter_route == :interview
    assert input_event.routing_decision.execution_route == :ouroboros_workflow

    refute_received {:command, _command_event, _args, _startup_result}

    assert {:ok, [journaled]} = Journal.read_ordered(journal_path)
    assert journaled.input_kind == :natural_language
    assert journaled.task_input == prompt
    assert routing_field(journaled.routing_decision, :execution_route) == :ouroboros_workflow
    assert routing_field(journaled.routing_decision, :adapter_route) == :interview
  end

  test "dispatches the normalized natural-language input event to the prompt processor" do
    parent = self()
    lines = start_lines(["Route a prompt through the normalized event\n", "/exit\n"])

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 on_prompt_input: fn task_request, input_event, startup_result ->
                   send(parent, {:prompt_processed, task_request, input_event, startup_result})
                 end
               })

      assert [input_event] = result.input_events
      assert [task_request] = result.submitted_tasks
      assert input_event.task_request_id == task_request.id
    end)

    assert_receive {:prompt_processed, task_request, input_event, %{status: :healthy}}
    assert task_request.task_input == "Route a prompt through the normalized event"
    assert task_request.id == input_event.task_request_id
    assert input_event.type == :prompt_input_submitted
    assert input_event.input_kind == :natural_language
  end

  test "reports handled command errors and keeps accepting later prompt input" do
    parent = self()
    lines = start_lines(["/pane missing-child\n", "Recover after command error\n", "/exit\n"])
    journal_path = journal_path("terminal-command-error")

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(%{status: :healthy}, %{
                   read_line: next_line(lines),
                   journal_path: journal_path,
                   on_command: fn command_event, args, startup_result ->
                     send(parent, {:command, command_event, args, startup_result})
                     {:error, {:unknown_pane, hd(args)}}
                   end,
                   on_command_error: fn command_error, command_event, startup_result ->
                     send(parent, {:command_error, command_error, command_event, startup_result})
                   end,
                   on_task: fn task_request, startup_result ->
                     send(parent, {:task_request, task_request, startup_result})
                   end
                 })

        assert result.status == :exit_signal_received
        assert result.iterations == 3

        assert [%{command: "/pane", args: ["missing-child"]}] = result.command_events
        assert [%{type: :slash_command_failed, command: "/pane"}] = result.command_errors

        assert Enum.map(result.submitted_tasks, & &1.task_input) == [
                 "Recover after command error"
               ]
      end)

    assert_receive {:command, %{command: "/pane"}, ["missing-child"], %{status: :healthy}}

    assert_receive {:command_error, %{reason: {:unknown_pane, "missing-child"}},
                    %{command: "/pane"}, %{status: :healthy}}

    assert_receive {:task_request, %{task_input: "Recover after command error"},
                    %{status: :healthy}}

    assert output =~ "command /pane failed: {:unknown_pane, \"missing-child\"}"
    assert output =~ "queued task"
    assert output =~ "exiting ourocode"

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, & &1.type) == [
             :slash_command_submitted,
             :slash_command_failed,
             :prompt_input_submitted
           ]
  end

  test "reserved builtin commands are journaled through the command path and keep the loop alive" do
    lines =
      start_lines([
        "/clear\n",
        "/resume\n",
        "Recover after commands\n",
        "/exit\n"
      ])

    journal_path = journal_path("terminal-reserved-builtins")

    output =
      capture_io(fn ->
        assert {:ok, loop_result} =
                 EventLoop.run(%{status: :healthy}, %{
                   read_line: next_line(lines),
                   journal_path: journal_path
                 })

        send(self(), {:reserved_builtin_result, loop_result})
      end)

    assert output =~ "queued task"
    assert_receive {:reserved_builtin_result, result}

    assert result.status == :exit_signal_received
    assert Enum.map(result.command_events, & &1.command) == ["/clear", "/resume"]
    assert [%{task_input: "Recover after commands"}] = result.submitted_tasks

    assert {:ok, journaled} = Journal.read_ordered(journal_path)
    assert Enum.any?(journaled, &(&1.type == :slash_command_submitted and &1.command == "/clear"))

    assert Enum.any?(
             journaled,
             &(&1.type == :slash_command_submitted and &1.command == "/resume")
           )
  end

  test "default help and status commands render visible registry and runtime summaries" do
    lines = start_lines(["/help\n", "/capabilities\n", "/status\n", "/plugins\n", "/exit\n"])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(
                   %{
                     status: :healthy,
                     runtime: %{
                       status: :ready,
                       journal: %{status: :ready},
                       queued_notifications: %{pending_count: 2},
                       hooks: %{event_count: 0},
                       plugins: [
                         %{
                           plugin_id: "ouroboros-plugin",
                           source_type: "official",
                           enabled?: true,
                           load_state: :loaded
                         }
                       ]
                     },
                     transports: [:stdio, :sse, :streamable_http]
                   },
                   %{read_line: next_line(lines)}
                 )

        send(self(), {:visible_command_result, result})
      end)

    assert output =~ "commands:"
    assert output =~ "/help [builtin/discovery]"
    assert output =~ "capabilities:"
    assert output =~ "/capabilities"
    assert output =~ "builtin/kernel/read_only/default"
    assert output =~ "+-- State"
    assert output =~ "queued=2"
    assert output =~ "transports=stdio:unknown,sse:unknown,streamable_http:unknown"
    assert output =~ "+-- Plugin Status (1)"
    assert output =~ "ouroboros-plugin"

    assert_receive {:visible_command_result, result}

    assert Enum.map(result.command_events, & &1.command) == [
             "/help",
             "/capabilities",
             "/status",
             "/plugins"
           ]
  end

  test "resume lists journaled sessions and reconnects by replaying a selected journal" do
    session_path = journal_path("terminal-resume-target")
    journal_dir = Path.dirname(session_path)
    session_id = Path.basename(session_path, ".jsonl")
    active_journal = Path.join(journal_dir, "terminal-resume-active.jsonl")

    Journal.append!(session_path, %{
      type: :parent_call_started,
      event_seq: 1,
      parent_call_id: "parent-resume-1",
      runtime_source: "test",
      transport: :streamable_http,
      occurred_at_ms: 1
    })

    lines = start_lines(["/resume\n", "/resume #{session_id}\n", "/exit\n"])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(%{status: :healthy}, %{
                   read_line: next_line(lines),
                   journal_path: active_journal
                 })

        send(self(), {:resume_result, result})
      end)

    assert output =~ "resume: journaled sessions"
    assert output =~ session_id
    assert output =~ "resumed #{session_id}: 1 events replayed"

    assert_receive {:resume_result, result}
    assert Enum.map(result.command_events, & &1.command) == ["/resume", "/resume"]
  end

  test "default cancel command dispatches cancellation to the resolved focused child session" do
    parent = self()
    child_pane_id = "child-session:cancel-bravo"
    sibling_pane_id = "child-session:cancel-alpha"

    pane_model = %{
      panes: %{
        sibling_pane_id => %{
          id: sibling_pane_id,
          kind: :child_session,
          child_id: "cancel-alpha",
          transport: :sse
        },
        child_pane_id => %{
          id: child_pane_id,
          kind: :child_session,
          child_id: "cancel-bravo",
          transport: :stdio
        },
        parent: %{id: :parent, kind: :parent_session}
      },
      open: [:parent, sibling_pane_id, child_pane_id]
    }

    focus_state = %{
      focused_pane: child_pane_id,
      steering_target: :child,
      steering_target_pane_id: child_pane_id,
      steering_target_session_id: "cancel-bravo",
      steering_target_kind: :child_session,
      route: :focused_pane,
      history: []
    }

    dispatcher = fn
      %{id: ^child_pane_id} = pane, serialized_request, context ->
        send(parent, {:cancel_dispatched_to_focus, pane, serialized_request, context})
        {:ok, :cancelled_focused_child}

      %{id: ^sibling_pane_id} = pane, serialized_request, context ->
        send(parent, {:cancel_dispatched_to_sibling, pane, serialized_request, context})
        {:ok, :cancelled_sibling}
    end

    journal_path = journal_path("terminal-cancel-focused-child")
    lines = start_lines(["/cancel stop current run\n", "/exit\n"])

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 focus_state: focus_state,
                 pane_model: pane_model,
                 command_dispatch_options: %{
                   child_session_cancel_dispatcher: dispatcher,
                   context: %{journal_scope: "terminal-cancel-test"}
                 }
               })

      assert result.status == :exit_signal_received
      assert [%{command: "/cancel", args: ["stop", "current", "run"]}] = result.command_events
      assert result.command_errors == []
    end)

    assert_receive {:cancel_dispatched_to_focus, %{id: ^child_pane_id}, serialized_request,
                    %{journal_scope: "terminal-cancel-test", decoded_request: decoded_request}}

    refute_received {:cancel_dispatched_to_sibling, _pane, _serialized_request, _context}

    assert decoded_request.type == "child_session_cancel_request"
    assert decoded_request.target_pane_id == child_pane_id
    assert decoded_request.target_session_id == "cancel-bravo"
    assert decoded_request.reason == "stop current run"

    assert {:ok, wire_request} = Json.decode(serialized_request)
    assert wire_request["type"] == "child_session_cancel_request"
    assert wire_request["action"] == "cancel"
    assert wire_request["target_pane_id"] == child_pane_id
    assert wire_request["target_session_id"] == "cancel-bravo"
    assert wire_request["source_command"] == "/cancel"
    assert wire_request["source_args"] == ["stop", "current", "run"]
    assert wire_request["reason"] == "stop current run"

    assert {:ok, journaled} = Journal.read_ordered(journal_path)
    assert Enum.map(journaled, & &1.type) == [:slash_command_submitted]
  end

  test "returns to awaiting prompt state after dispatched input completes" do
    lines = start_lines(["Dispatch then await again\n", "/exit\n"])
    {:ok, transitions} = Agent.start_link(fn -> [] end)

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 on_prompt_state_change: fn state_event, _startup_result ->
                   Agent.update(transitions, &[{:state, state_event.prompt_state} | &1])
                 end,
                 on_prompt_input: fn task_request, input_event, _startup_result ->
                   Agent.update(transitions, &[{:dispatch, :started} | &1])
                   assert task_request.id == input_event.task_request_id
                   Agent.update(transitions, &[{:dispatch, :completed} | &1])
                 end
               })

      assert result.prompt_state == :awaiting_prompt

      assert Enum.map(result.prompt_state_events, & &1.prompt_state) == [
               :dispatching_input,
               :awaiting_prompt
             ]

      assert Enum.map(result.prompt_state_events, & &1.reason) == [
               :input_dispatch_started,
               :input_dispatch_completed
             ]

      assert [input_event] = result.input_events

      assert Enum.all?(
               result.prompt_state_events,
               &(&1.task_request_id == input_event.task_request_id)
             )
    end)

    assert Agent.get(transitions, &Enum.reverse/1) == [
             {:state, :dispatching_input},
             {:dispatch, :started},
             {:dispatch, :completed},
             {:state, :awaiting_prompt}
           ]
  end

  test "continues accepting subsequent input after a completed prompt response" do
    parent = self()

    lines =
      start_lines([
        "Summarize parent pane state\n",
        "Now steer the child pane\n",
        "/exit\n"
      ])

    {:ok, transitions} = Agent.start_link(fn -> [] end)

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 on_prompt_state_change: fn state_event, _startup_result ->
                   Agent.update(transitions, &[state_event.prompt_state | &1])
                 end,
                 on_prompt_input: fn task_request, input_event, startup_result ->
                   assert task_request.id == input_event.task_request_id
                   send(parent, {:prompt_completed, task_request.task_input, startup_result})
                   :ok
                 end
               })

      assert result.status == :exit_signal_received
      assert result.exit_signal == "/exit"
      assert result.iterations == 3
      assert result.prompt_state == :awaiting_prompt

      assert Enum.map(result.submitted_tasks, & &1.task_input) == [
               "Summarize parent pane state",
               "Now steer the child pane"
             ]

      assert Enum.map(result.input_events, & &1.task_input) == [
               "Summarize parent pane state",
               "Now steer the child pane"
             ]

      assert Enum.map(result.prompt_state_events, & &1.prompt_state) == [
               :dispatching_input,
               :awaiting_prompt,
               :dispatching_input,
               :awaiting_prompt
             ]

      assert Enum.map(result.prompt_state_events, & &1.reason) == [
               :input_dispatch_started,
               :input_dispatch_completed,
               :input_dispatch_started,
               :input_dispatch_completed
             ]
    end)

    assert_receive {:prompt_completed, "Summarize parent pane state", %{status: :healthy}}
    assert_receive {:prompt_completed, "Now steer the child pane", %{status: :healthy}}

    assert Agent.get(transitions, &Enum.reverse/1) == [
             :dispatching_input,
             :awaiting_prompt,
             :dispatching_input,
             :awaiting_prompt
           ]
  end

  test "runtime activity and recoverable errors do not trigger application shutdown" do
    parent = self()

    lines =
      start_lines([
        "non-exit prompt after runtime activity\n",
        "/exit\n"
      ])

    runtime_events =
      start_lines([
        %{
          type: :child_stream_event,
          source: :stdio,
          child_id: "child-stream-1",
          payload: %{token: "visible"}
        },
        %{
          type: :child_pane_focused,
          source: :pane_model,
          pane_id: "child-session:child-stream-1"
        },
        %{
          type: :plugin_loaded,
          source: :plugin_registry,
          plugin: "vim-mode",
          provenance: :third_party
        },
        %{
          type: :recoverable_error,
          source: :event_pipeline,
          recoverable?: true,
          reason: :temporary_backpressure
        }
      ])

    journal_path = journal_path("terminal-runtime-activity")

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(%{status: :healthy}, %{
                   read_line: next_line(lines),
                   poll_runtime_event: next_line(runtime_events),
                   journal_path: journal_path,
                   on_runtime_event: fn runtime_event, startup_result ->
                     send(parent, {:runtime_event, runtime_event, startup_result})
                     :ok
                   end,
                   on_task: fn task_request, startup_result ->
                     send(parent, {:task_request, task_request, startup_result})
                   end
                 })

        assert result.status == :exit_signal_received
        assert result.exit_signal == "/exit"
        assert result.iterations == 2

        assert Enum.map(result.runtime_events, & &1.type) == [
                 :child_stream_event,
                 :child_pane_focused,
                 :plugin_loaded,
                 :recoverable_error
               ]

        assert [%{error_type: :recoverable_error, reason: :temporary_backpressure}] =
                 result.recoverable_errors

        assert Enum.map(result.submitted_tasks, & &1.task_input) == [
                 "non-exit prompt after runtime activity"
               ]
      end)

    assert_receive {:runtime_event, %{type: :child_stream_event}, %{status: :healthy}}
    assert_receive {:runtime_event, %{type: :child_pane_focused}, %{status: :healthy}}
    assert_receive {:runtime_event, %{type: :plugin_loaded}, %{status: :healthy}}
    assert_receive {:runtime_event, %{type: :recoverable_error}, %{status: :healthy}}

    assert_receive {:task_request, %{task_input: "non-exit prompt after runtime activity"},
                    %{status: :healthy}}

    assert output =~ "queued task"
    assert output =~ "exiting ourocode"

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, & &1.type) == [
             :child_stream_event,
             :child_pane_focused,
             :plugin_loaded,
             :recoverable_error,
             :prompt_input_submitted
           ]
  end

  test "accepted exit drains pending runtime events before releasing resources" do
    parent = self()
    lines = start_lines(["/exit\n"])
    journal_path = journal_path("terminal-exit-flush")

    pending_runtime_events =
      start_lines([
        %{
          type: :child_stream_event,
          source: :stdio,
          child_id: "child-exit-flush-1",
          payload: %{token: "last visible token"}
        },
        %{
          type: :hook_completed,
          source: :hook_lifecycle,
          hook_id: "hook-exit-flush-1",
          payload: %{summary: "cleanup hook finished"}
        }
      ])

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 poll_runtime_event: fn state ->
                   if state.iterations > 0 do
                     next_line(pending_runtime_events).(:unused_prompt)
                   else
                     :none
                   end
                 end,
                 on_runtime_event: fn runtime_event, _startup_result ->
                   send(parent, {:shutdown_order, {:runtime_event, runtime_event.type}})
                   :ok
                 end,
                 on_release_resources: fn _startup_result, state ->
                   send(
                     parent,
                     {:shutdown_order, {:release_resources, length(state.runtime_events)}}
                   )

                   :ok
                 end
               })

      assert result.status == :exit_signal_received
      assert result.exit_signal == "/exit"
      assert result.resources_released? == true

      assert Enum.map(result.runtime_events, & &1.type) == [
               :child_stream_event,
               :hook_completed
             ]
    end)

    assert_receive {:shutdown_order, {:runtime_event, :child_stream_event}}
    assert_receive {:shutdown_order, {:runtime_event, :hook_completed}}
    assert_receive {:shutdown_order, {:release_resources, 2}}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, & &1.type) == [
             :child_stream_event,
             :hook_completed
           ]
  end

  test "dispatch_prompt_input_event rebuilds task request from normalized event" do
    assert {:ok, {_task_request, input_event}} =
             EventLoop.normalize_input_line("Investigate prompt processing",
               id: "normalized-event-task",
               submitted_at_ms: 88
             )

    parent = self()

    assert {:ok, dispatched_task_request} =
             EventLoop.dispatch_prompt_input_event(input_event, %{status: :healthy},
               on_prompt_input: fn task_request, event, startup_result ->
                 send(parent, {:prompt_processed, task_request, event, startup_result})
               end
             )

    assert dispatched_task_request.id == "normalized-event-task"
    assert dispatched_task_request.task_input == "Investigate prompt processing"

    assert_receive {:prompt_processed, ^dispatched_task_request, ^input_event,
                    %{status: :healthy}}
  end

  test "dispatch_prompt_input_event rejects non natural-language events" do
    assert EventLoop.dispatch_prompt_input_event(
             %{type: :slash_command_submitted, input_kind: :slash_command},
             %{status: :healthy}
           ) == {:error, {:unsupported_input_kind, :slash_command}}
  end

  test "command input switches focus when the target pane differs from the current pane" do
    parent = self()

    lines =
      start_lines([
        "/pane children\n",
        "/exit\n"
      ])

    journal_path = journal_path("terminal-command-focus-switch")

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 focus_state: %{
                   focused_pane: :parent,
                   steering_target: :parent,
                   route: :test,
                   history: []
                 },
                 pane_model: %{
                   panes: %{
                     parent: %{id: :parent, kind: :parent_session},
                     children: %{id: :children, kind: :child_sessions}
                   },
                   open: [:parent, :children]
                 },
                 on_command: fn command_event, args, startup_result ->
                   send(parent, {:command, command_event, args, startup_result})
                   :ok
                 end,
                 on_focus_event: fn focus_event, startup_result ->
                   send(parent, {:focus_event, focus_event, startup_result})
                 end
               })

      assert result.status == :exit_signal_received
      assert result.iterations == 2
      assert result.focus_state.focused_pane == :children
      assert result.focus_state.previous_focused_pane == :parent
      assert result.focus_state.steering_target == :child

      assert [
               %{
                 type: :focus_state_updated,
                 source: :terminal_command,
                 input_kind: :slash_command,
                 command: "/pane",
                 args: ["children"],
                 previous_focused_pane: :parent,
                 focused_pane: :children,
                 steering_target: :child
               }
             ] = result.focus_events

      assert [%{command: "/pane", args: ["children"]}] = result.command_events
    end)

    assert_receive {:focus_event,
                    %{
                      source: :terminal_command,
                      previous_focused_pane: :parent,
                      focused_pane: :children
                    }, %{status: :healthy}}

    assert_receive {:command, %{command: "/pane"}, ["children"], %{status: :healthy}}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, & &1.type) == [
             :slash_command_submitted,
             :focus_state_updated
           ]

    assert [%{source: :terminal_command, focused_pane: "children"}] =
             Enum.filter(journaled, &(&1.type == :focus_state_updated))
  end

  test "routes prompt input after a focus switch only to the newly focused pane" do
    parent = self()

    lines =
      start_lines([
        "/pane children\n",
        "Summarize the focused child pane\n",
        "/exit\n"
      ])

    journal_path = journal_path("terminal-input-after-focus-switch")

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 focus_state: %{
                   focused_pane: :parent,
                   steering_target: :parent,
                   route: :test,
                   history: []
                 },
                 pane_model: %{
                   panes: %{
                     parent: %{id: :parent, kind: :parent_session},
                     children: %{id: :children, kind: :child_sessions}
                   },
                   open: [:parent, :children]
                 },
                 on_command: fn command_event, args, startup_result ->
                   send(parent, {:command, command_event, args, startup_result})
                   :ok
                 end,
                 on_prompt_input: fn task_request, input_event, startup_result ->
                   send(parent, {:prompt_routed, task_request, input_event, startup_result})
                   :ok
                 end
               })

      assert result.focus_state.focused_pane == :children
      assert result.focus_state.previous_focused_pane == :parent
      assert result.focus_state.steering_target == :child

      assert [
               %{
                 task_input: "Summarize the focused child pane",
                 focused_pane: :children,
                 steering_target: :child,
                 payload: %{
                   focused_pane: :children,
                   steering_target: :child
                 }
               } = input_event
             ] = result.input_events

      refute Map.has_key?(input_event, :previous_focused_pane)
    end)

    assert_receive {:command, %{command: "/pane"}, ["children"], %{status: :healthy}}

    assert_receive {:prompt_routed, %{task_input: "Summarize the focused child pane"},
                    %{
                      focused_pane: :children,
                      steering_target: :child,
                      payload: %{focused_pane: :children}
                    }, %{status: :healthy}}

    refute_receive {:prompt_routed, _task_request, %{focused_pane: :parent}, _startup_result}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, & &1.type) == [
             :slash_command_submitted,
             :focus_state_updated,
             :prompt_input_submitted
           ]

    assert %{focused_pane: "children", steering_target: :child, payload: payload} =
             List.last(journaled)

    assert payload["focused_pane"] == "children"
    assert payload["steering_target"] == "child"
  end

  test "routes prompt input to the concrete focused child pane steering target" do
    parent = self()
    child_pane_id = "child-session:steering-bravo"

    lines =
      start_lines([
        "/pane #{child_pane_id}\n",
        "transport는 stdio, SSE, streamable HTTP 모두 필요해.\n",
        "/exit\n"
      ])

    journal_path = journal_path("terminal-input-focused-child-pane-target")

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 focus_state: %{
                   focused_pane: :parent,
                   steering_target: :parent,
                   route: :test,
                   history: []
                 },
                 pane_model: %{
                   panes: %{
                     child_pane_id => %{
                       id: child_pane_id,
                       kind: :child_session,
                       child_id: "steering-bravo",
                       transport: :stdio
                     },
                     parent: %{id: :parent, kind: :parent_session}
                   },
                   open: [:parent, child_pane_id]
                 },
                 on_command: fn command_event, args, startup_result ->
                   send(parent, {:command, command_event, args, startup_result})
                   :ok
                 end,
                 on_prompt_input: fn task_request, input_event, startup_result ->
                   send(parent, {:prompt_routed, task_request, input_event, startup_result})
                   :ok
                 end
               })

      assert result.focus_state.focused_pane == child_pane_id
      assert result.focus_state.steering_target == :child
      assert result.focus_state.steering_target_pane_id == child_pane_id
      assert result.focus_state.steering_target_session_id == "steering-bravo"
      assert result.focus_state.steering_target_kind == :child_session

      assert [
               %{
                 focused_pane: ^child_pane_id,
                 steering_target: :child,
                 steering_target_pane_id: ^child_pane_id,
                 steering_target_session_id: "steering-bravo",
                 steering_target_kind: :child_session,
                 payload: %{
                   steering_target_pane_id: ^child_pane_id,
                   steering_target_session_id: "steering-bravo",
                   steering_target_kind: :child_session
                 }
               }
             ] = result.input_events
    end)

    assert_receive {:command, %{command: "/pane"}, [^child_pane_id], %{status: :healthy}}

    assert_receive {:prompt_routed,
                    %{task_input: "transport는 stdio, SSE, streamable HTTP 모두 필요해."},
                    %{
                      focused_pane: ^child_pane_id,
                      steering_target: :child,
                      steering_target_pane_id: ^child_pane_id,
                      steering_target_session_id: "steering-bravo"
                    }, %{status: :healthy}}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert %{type: :focus_state_updated, steering_target_pane_id: ^child_pane_id} =
             Enum.find(journaled, &(&1.type == :focus_state_updated))

    assert %{type: :prompt_input_submitted, steering_target_pane_id: ^child_pane_id} =
             Enum.find(journaled, &(&1.type == :prompt_input_submitted))
  end

  test "preserves exact free-form steering text for the focused pane" do
    parent = self()
    child_pane_id = "child-session:steering-exact"
    steering_text = " \t keep  spacing && symbols: []{}|$`'\" 한글  "

    lines =
      start_lines([
        "/pane #{child_pane_id}\n",
        steering_text <> "\n",
        "/exit\n"
      ])

    journal_path = journal_path("terminal-exact-steering-text")

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 focus_state: %{
                   focused_pane: :parent,
                   steering_target: :parent,
                   route: :test,
                   history: []
                 },
                 pane_model: %{
                   panes: %{
                     child_pane_id => %{
                       id: child_pane_id,
                       kind: :child_session,
                       child_id: "steering-exact"
                     },
                     parent: %{id: :parent, kind: :parent_session}
                   },
                   open: [:parent, child_pane_id]
                 },
                 on_prompt_input: fn task_request, input_event, startup_result ->
                   send(parent, {:prompt_routed, task_request, input_event, startup_result})
                   :ok
                 end
               })

      assert [
               %{
                 task_input: "keep spacing && symbols: []{}|$`'\" 한글",
                 raw_input: ^steering_text,
                 steering_text: ^steering_text,
                 steering_target_pane_id: ^child_pane_id,
                 steering_message: %{
                   type: :pane_directed_steering_message,
                   target_pane_id: ^child_pane_id,
                   content: ^steering_text
                 },
                 payload: %{
                   raw_input: ^steering_text,
                   steering_text: ^steering_text,
                   steering_target_pane_id: ^child_pane_id,
                   steering_message: %{
                     type: :pane_directed_steering_message,
                     target_pane_id: ^child_pane_id,
                     content: ^steering_text
                   }
                 }
               }
             ] = result.input_events
    end)

    assert_receive {:prompt_routed, %{task_input: "keep spacing && symbols: []{}|$`'\" 한글"},
                    %{
                      raw_input: ^steering_text,
                      steering_text: ^steering_text,
                      steering_target_pane_id: ^child_pane_id,
                      steering_message: %{
                        type: :pane_directed_steering_message,
                        target_pane_id: ^child_pane_id,
                        content: ^steering_text
                      }
                    }, %{status: :healthy}}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert %{
             raw_input: ^steering_text,
             steering_text: ^steering_text,
             steering_message: steering_message,
             payload: payload
           } =
             Enum.find(journaled, &(&1.type == :prompt_input_submitted))

    assert steering_message["target_pane_id"] == child_pane_id
    assert steering_message["content"] == steering_text
    assert payload["raw_input"] == steering_text
    assert payload["steering_text"] == steering_text
    assert payload["steering_message"]["target_pane_id"] == child_pane_id
    assert payload["steering_message"]["content"] == steering_text
  end

  test "appends child steering messages to the target pane stream in processing order" do
    child_pane_id = "child-session:stream-target"
    sibling_pane_id = "child-session:stream-sibling"

    lines =
      start_lines([
        "first child-directed message\n",
        "second child-directed message\n",
        "/exit\n"
      ])

    journal_path = journal_path("terminal-child-steering-stream-order")

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 focus_state: %{
                   focused_pane: child_pane_id,
                   steering_target: :child,
                   steering_target_pane_id: child_pane_id,
                   steering_target_session_id: "stream-target",
                   steering_target_kind: :child_session,
                   route: :focused_pane,
                   history: []
                 },
                 pane_model: %{
                   panes: %{
                     child_pane_id => %{
                       id: child_pane_id,
                       kind: :child_session,
                       child_id: "stream-target",
                       pane_state: %{
                         stream_entries: [
                           %{
                             type: :child_stream_event,
                             event_seq: 0,
                             content: "existing child output"
                           }
                         ]
                       }
                     },
                     sibling_pane_id => %{
                       id: sibling_pane_id,
                       kind: :child_session,
                       child_id: "stream-sibling",
                       pane_state: %{stream_entries: []}
                     },
                     parent: %{id: :parent, kind: :parent_session}
                   },
                   open: [:parent, child_pane_id, sibling_pane_id]
                 },
                 on_prompt_input: fn _task_request, _input_event, _startup_result ->
                   :ok
                 end
               })

      assert result.status == :exit_signal_received

      target_entries =
        result.pane_model.panes
        |> Map.fetch!(child_pane_id)
        |> get_in([:pane_state, :stream_entries])

      assert Enum.map(target_entries, & &1.event_seq) == [0, 1, 2]

      assert [
               %{type: :child_stream_event, content: "existing child output"},
               %{
                 type: :pane_directed_steering_message,
                 event_seq: 1,
                 content: "first child-directed message",
                 target_pane_id: ^child_pane_id,
                 target_session_id: "stream-target"
               },
               %{
                 type: :pane_directed_steering_message,
                 event_seq: 2,
                 content: "second child-directed message",
                 target_pane_id: ^child_pane_id,
                 target_session_id: "stream-target"
               }
             ] = target_entries

      assert result.pane_model.panes[sibling_pane_id].pane_state.stream_entries == []
      assert result.pane_model.panes[child_pane_id].pane_state.last_event_seq == 2
    end)

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, & &1.type) == [
             :prompt_input_submitted,
             :prompt_input_submitted
           ]
  end

  test "keyboard input switches focus when the target pane differs from the current pane" do
    parent = self()

    lines =
      start_lines([
        %{input_kind: :keyboard, key: :tab},
        "/exit\n"
      ])

    journal_path = journal_path("terminal-keyboard-focus-switch")

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 focus_state: %{
                   focused_pane: :parent,
                   steering_target: :parent,
                   route: :test,
                   history: []
                 },
                 pane_model: %{
                   panes: %{
                     parent: %{id: :parent, kind: :parent_session},
                     children: %{id: :children, kind: :child_sessions}
                   },
                   open: [:parent, :children]
                 },
                 keyboard_focus_bindings: %{tab: :children},
                 on_focus_event: fn focus_event, startup_result ->
                   send(parent, {:focus_event, focus_event, startup_result})
                 end
               })

      assert result.status == :exit_signal_received
      assert result.iterations == 2
      assert result.focus_state.focused_pane == :children
      assert result.focus_state.previous_focused_pane == :parent
      assert result.focus_state.steering_target == :child

      assert [
               %{
                 type: :focus_state_updated,
                 source: :terminal_keyboard,
                 input_kind: :keyboard,
                 previous_focused_pane: :parent,
                 focused_pane: :children,
                 steering_target: :child,
                 key: :tab
               }
             ] = result.focus_events
    end)

    assert_receive {:focus_event,
                    %{
                      source: :terminal_keyboard,
                      previous_focused_pane: :parent,
                      focused_pane: :children
                    }, %{status: :healthy}}

    assert {:ok, [journaled]} = Journal.read_ordered(journal_path)
    assert journaled.type == :focus_state_updated
    assert journaled.source == :terminal_keyboard
    assert journaled.focused_pane == "children"
  end

  test "keyboard input for the current pane is a no-op and does not journal a focus event" do
    lines =
      start_lines([
        %{input_kind: :keyboard, key: :tab, target_pane_id: :children},
        "/exit\n"
      ])

    journal_path = journal_path("terminal-keyboard-focus-noop")

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 focus_state: %{
                   focused_pane: :children,
                   steering_target: :child,
                   route: :focused_pane,
                   history: []
                 },
                 pane_model: %{
                   panes: %{
                     parent: %{id: :parent, kind: :parent_session},
                     children: %{id: :children, kind: :child_sessions}
                   },
                   open: [:parent, :children]
                 }
               })

      assert result.status == :exit_signal_received
      assert result.focus_state.focused_pane == :children
      assert result.focus_events == []
    end)

    refute File.exists?(journal_path)
  end

  test "command input for the current pane is a no-op and journals only the command" do
    parent = self()

    lines =
      start_lines([
        "/pane children\n",
        "/exit\n"
      ])

    journal_path = journal_path("terminal-command-focus-noop")

    capture_io(fn ->
      assert {:ok, result} =
               EventLoop.run(%{status: :healthy}, %{
                 read_line: next_line(lines),
                 journal_path: journal_path,
                 focus_state: %{
                   focused_pane: :children,
                   steering_target: :child,
                   route: :focused_pane,
                   history: []
                 },
                 pane_model: %{
                   panes: %{
                     parent: %{id: :parent, kind: :parent_session},
                     children: %{id: :children, kind: :child_sessions}
                   },
                   open: [:parent, :children]
                 },
                 on_command: fn command_event, args, startup_result ->
                   send(parent, {:command, command_event, args, startup_result})
                   :ok
                 end,
                 on_focus_event: fn focus_event, startup_result ->
                   send(parent, {:focus_event, focus_event, startup_result})
                 end
               })

      assert result.status == :exit_signal_received
      assert result.focus_state.focused_pane == :children
      assert result.focus_events == []
      assert [%{command: "/pane", args: ["children"]}] = result.command_events
    end)

    assert_receive {:command, %{command: "/pane"}, ["children"], %{status: :healthy}}
    refute_receive {:focus_event, _focus_event, _startup_result}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)
    assert Enum.map(journaled, & &1.type) == [:slash_command_submitted]
  end

  test "normalizes one input line without requiring slash-command syntax" do
    assert {:ok,
            {task_request,
             %{
               type: :prompt_input_submitted,
               source: :terminal_prompt,
               input_kind: :natural_language,
               task_input: "Compare stdio and SSE event streams",
               routing_decision: %{requires_command_syntax?: false}
             }}} =
             EventLoop.normalize_input_line(" Compare stdio\nand SSE event streams ",
               id: "prompt-input-test",
               submitted_at_ms: 1_234
             )

    assert task_request.id == "prompt-input-test"
    assert task_request.task_input == "Compare stdio and SSE event streams"
  end

  test "exits safely on EOF for piped or non-interactive runs" do
    assert {:ok, result} =
             EventLoop.run(%{status: :healthy}, read_line: fn _prompt -> nil end)

    assert result.status == :input_eof
    assert result.iterations == 0
    assert result.submitted_tasks == []
  end

  test "consumes piped prompt input until EOF without requiring an exit command" do
    parent = self()

    lines =
      start_lines([
        "Summarize parent state from stdin\n",
        "Route child stream from stdin\n"
      ])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(%{status: :healthy}, %{
                   read_line: next_line(lines),
                   on_task: fn task_request, startup_result ->
                     send(parent, {:task_request, task_request, startup_result})
                   end
                 })

        assert result.status == :input_eof
        assert result.exit_signal == nil
        assert result.iterations == 2

        assert Enum.map(result.submitted_tasks, & &1.task_input) == [
                 "Summarize parent state from stdin",
                 "Route child stream from stdin"
               ]
      end)

    assert_receive {:task_request, %{task_input: "Summarize parent state from stdin"},
                    %{status: :healthy}}

    assert_receive {:task_request, %{task_input: "Route child stream from stdin"},
                    %{status: :healthy}}

    assert output =~ "queued task"
    refute output =~ "exiting ourocode"
  end

  test "plugin config reload events refresh the visible plugin status without UI restart" do
    project_dir = tmp_dir!("terminal-plugin-status-propagation")
    config_path = Path.join(project_dir, ".ourocode/config.json")
    journal_path = Path.join(project_dir, ".ourocode/journals/reload.jsonl")
    File.mkdir_p!(Path.dirname(config_path))
    File.mkdir_p!(Path.dirname(journal_path))
    File.write!(config_path, plugin_config_json("ouroboros-plugin", true))

    assert {:ok, runtime} =
             Ourocode.Runtime.Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-plugin-status-propagation",
               journal_path: journal_path,
               plugin_config_source_paths: [config_path],
               plugin_config_watcher_poll_interval_ms: false
             })

    on_exit(fn ->
      Ourocode.Runtime.Application.stop(runtime)
      File.rm_rf!(project_dir)
    end)

    lines = start_lines(["/exit\n"])
    runtime_events = start_lines([reload_request(config_path, :created)])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(
                   %{
                     status: :healthy,
                     runtime: runtime,
                     context: %{project_dir: project_dir, runtime: runtime}
                   },
                   read_line: next_line(lines),
                   poll_runtime_event: next_line(runtime_events),
                   journal_path: journal_path
                 )

        assert result.status == :exit_signal_received
        assert [%{type: :plugin_config_reload_requested}] = result.runtime_events

        assert [
                 %{
                   type: :terminal_plugin_status_updated,
                   status: :loaded,
                   ui_restart_required?: false,
                   rendered_area: %{plugin_count: 1, items: [plugin_item]}
                 }
               ] = result.plugin_status_updates

        assert plugin_item.plugin_id == "ouroboros-plugin"
        assert plugin_item.source_type == "official"
        assert plugin_item.enabled? == true
        assert plugin_item.load_state == :newly_loaded
      end)

    assert output =~ "+-- Plugin Status (1) region=plugin_status"
    assert output =~ "[OFFICIAL] id=ouroboros-plugin"
    assert output =~ "state=newly_loaded"
    assert output =~ "exiting ourocode"

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, &journaled_type/1) == [
             :plugin_config_reload_requested,
             :plugin_config_reloaded
           ]
  end

  test "plugin status UI renders newly loaded plugins on the next cycle after hot reload" do
    lines = start_lines(["/exit\n"])
    runtime_events = start_lines([plugin_config_reloaded_event()])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 EventLoop.run(%{status: :healthy}, %{
                   read_line: next_line(lines),
                   poll_runtime_event: next_line(runtime_events)
                 })

        assert result.status == :exit_signal_received

        assert [%{type: :plugin_config_reloaded}] = result.runtime_events

        assert [
                 %{
                   type: :terminal_plugin_status_updated,
                   status: :loaded,
                   ui_restart_required?: false,
                   rendered_area: %{plugin_count: 2, items: items}
                 }
               ] = result.plugin_status_updates

        assert Enum.map(items, & &1.plugin_id) == ["ouroboros-plugin", "vim-mode"]
        assert Enum.map(items, & &1.load_state) == [:newly_loaded, :newly_loaded]
        assert Enum.map(items, & &1.enabled?) == [true, true]
      end)

    assert output =~ "+-- Plugin Status (2) region=plugin_status"
    assert output =~ "[OFFICIAL] id=ouroboros-plugin"
    assert output =~ "[THIRD-PARTY] id=vim-mode"
    assert output =~ "state=newly_loaded"
    assert output =~ "exiting ourocode"
  end

  defp start_lines(lines) do
    {:ok, pid} = Agent.start_link(fn -> lines end)
    pid
  end

  defp next_line(lines) do
    fn _prompt ->
      Agent.get_and_update(lines, fn
        [] -> {nil, []}
        [line | rest] -> {line, rest}
      end)
    end
  end

  defp journal_path(name) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")

    File.rm(path)
    path
  end

  defp reload_request(config_path, change) do
    %{
      type: :plugin_config_reload_requested,
      event_type: :plugin_config_reload_requested,
      source: :plugin_config_watcher,
      change: change,
      reason: :plugin_config_source_changed,
      config_source_path: Path.expand(config_path),
      config_source_relative_path: ".ourocode/config.json",
      occurred_at_ms: System.system_time(:millisecond),
      reload_boundary: :elixir_runtime,
      ui_restart_required?: false,
      request_id: "reload-#{change}"
    }
  end

  defp plugin_config_json(plugin_id, enabled?) do
    Ourocode.Json.encode!(%{
      "plugins" => [
        %{
          "identity" => %{"id" => plugin_id, "version" => "0.1.0"},
          "path" => "plugins/ouroboros",
          "entrypoint" => %{"type" => "manifest", "path" => "capabilities.json"},
          "enabled" => enabled?,
          "source" => "official",
          "permissions" => %{"filesystem" => [], "network" => [], "process" => []},
          "config" => %{"commands" => true, "skills" => true}
        }
      ]
    })
  end

  defp plugin_config_reloaded_event do
    %{
      type: :plugin_config_reloaded,
      event_type: :plugin_config_reloaded,
      source: :plugin_registry,
      status: :loaded,
      request_id: "reload-loaded",
      change: :modified,
      configured_plugins: [
        %{
          id: "ouroboros-plugin",
          source: "official",
          version: "0.1.0",
          enabled?: true,
          state: :enabled,
          path: "plugins/ouroboros"
        },
        %{
          id: "vim-mode",
          source: "third_party",
          version: "1.4.2",
          enabled?: true,
          state: :enabled,
          path: "plugins/vim-mode"
        }
      ],
      enabled_plugins: ["ouroboros-plugin", "vim-mode"],
      disabled_plugins: [],
      load_transitions: [
        %{
          plugin_id: "ouroboros-plugin",
          from: :unconfigured,
          to: :enabled,
          action: :load_requested,
          reason: :enabled_in_config
        },
        %{
          plugin_id: "vim-mode",
          from: :unconfigured,
          to: :enabled,
          action: :load_requested,
          reason: :enabled_in_config
        }
      ],
      occurred_at_ms: System.system_time(:millisecond),
      reload_boundary: :elixir_runtime,
      ui_restart_required?: false
    }
  end

  defp tmp_dir!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-#{name}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp journaled_type(event) do
    event
    |> Map.get(:type, Map.get(event, "type"))
    |> normalize_journaled_type()
  end

  defp normalize_journaled_type(value) when is_binary(value), do: String.to_existing_atom(value)
  defp normalize_journaled_type(value), do: value

  defp routing_field(routing_decision, field) do
    routing_decision
    |> Map.get(field, Map.get(routing_decision, Atom.to_string(field)))
    |> normalize_routing_field()
  end

  defp normalize_routing_field(value) when is_binary(value), do: String.to_existing_atom(value)
  defp normalize_routing_field(value), do: value
end
