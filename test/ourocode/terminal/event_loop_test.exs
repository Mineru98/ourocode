defmodule Ourocode.Terminal.EventLoopTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.{Registry, RegistryEntryAdapter}
  alias Ourocode.Terminal.EventLoop
  alias Ourocode.Terminal.NetworkListenerGuard
  alias Ourocode.Journal

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
    assert output_text =~ "task: queued"
    assert output_text =~ "exiting ourocode"
  end

  test "keeps reading natural-language prompts until an explicit exit signal" do
    parent = self()

    {result, output} =
      capture_event_loop(
        %{status: :healthy},
        [
          "Inspect parent panes\n",
          "Route this to child\n",
          "/exit\n"
        ],
        on_task: fn task_request, startup_result ->
          send(parent, {:task_request, task_request, startup_result})
        end
      )

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

    assert_receive {:task_request, %{task_input: "Inspect parent panes"}, %{status: :healthy}}
    assert_receive {:task_request, %{task_input: "Route this to child"}, %{status: :healthy}}
    assert output =~ "task: queued"
    assert output =~ "exiting ourocode"
  end

  test "children command shows the queued workflow workspace after ooo submission" do
    {result, output} =
      capture_event_loop(
        %{status: :healthy},
        [
          "ooo pm build onboarding\n",
          "/children\n",
          "/exit\n"
        ],
        on_task: fn _task_request, _startup_result -> :ok end
      )

    assert result.status == :exit_signal_received
    assert [%{task_input: "ooo pm build onboarding"}] = result.submitted_tasks

    assert output =~ "PM interview: starting - ooo pm build onboarding"
    assert output =~ "sessions: 1 active"
    assert output =~ "preparing question  ooo pm build onboarding"
    assert output =~ "last waiting for first PM question"
    refute output =~ "no delegated work yet"
  end

  test "continues prompt loop for exit-like natural language and slash near matches" do
    parent = self()

    {result, output} =
      capture_event_loop(
        %{status: :healthy},
        [
          "please exit the child pane after replay\n",
          "/exit now\n",
          "quit after summarizing the queue\n",
          "done\n"
        ],
        exit_signals: ["done"],
        on_task: fn task_request, startup_result ->
          send(parent, {:task_request, task_request, startup_result})
        end,
        on_command: fn command_event, args, startup_result ->
          send(parent, {:command, command_event, args, startup_result})
          :ok
        end
      )

    assert result.status == :exit_signal_received
    assert result.exit_signal == "done"
    assert result.iterations == 4

    assert Enum.map(result.submitted_tasks, & &1.task_input) == [
             "please exit the child pane after replay",
             "quit after summarizing the queue"
           ]

    assert [%{command: "/exit", args: ["now"]}] = result.command_events

    assert_receive {:task_request, %{task_input: "please exit the child pane after replay"},
                    %{status: :healthy}}

    assert_receive {:command, %{command: "/exit"}, ["now"], %{status: :healthy}}

    assert_receive {:task_request, %{task_input: "quit after summarizing the queue"},
                    %{status: :healthy}}

    assert output =~ "task: queued"
    assert output =~ "exiting ourocode"
  end

  test "unknown slash commands suggest nearby registered commands" do
    {result, output} =
      capture_event_loop(%{status: :healthy}, ["/capabilites\n", "/exit\n"])

    assert [%{command: "/capabilites"}] = result.command_events

    assert [%{reason: {:unknown_command, "/capabilites", suggestions}}] =
             result.command_errors

    assert "/capabilities" in suggestions

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
                 registry: %{loaded_count: loaded_count}
               }
             ] = result.command_palette_events

      assert loaded_count > 0
    end)

    assert_receive {:palette_opened,
                    %{
                      action: :command_palette_open,
                      raw_input: "/"
                    }, ^startup_result}

    assert_receive {:prompt_processed, %{task_input: "Prompt after palette"},
                    %{input_kind: :natural_language}, ^startup_result}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, &Map.get(&1, :type, Map.get(&1, "type"))) == [
             :command_palette_opened,
             :prompt_input_submitted
           ]
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
                   selected_slash: "/ship-it"
                 }
               ] = result.command_palette_events
      end)

    assert output =~ "help"
    assert output =~ "/config"
    assert output =~ "/theme"
    assert output =~ "selected /ship-it: Run the local ship workflow."

    assert_receive {:palette_selected,
                    %{
                      type: :command_palette_selected,
                      selected_slash: "/ship-it"
                    }, %{status: :healthy, commands: ^registry}}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, &Map.get(&1, :type, Map.get(&1, "type"))) == [
             :command_palette_opened,
             :command_palette_selected
           ]
  end

  test "ignores empty input and continues accepting subsequent prompts" do
    parent = self()

    {result, output} =
      capture_event_loop(
        %{status: :healthy},
        [
          "\n",
          "   \t\n",
          "Recover after blank input\n",
          "/exit\n"
        ],
        on_task: fn task_request, startup_result ->
          send(parent, {:task_request, task_request, startup_result})
        end
      )

    assert result.status == :exit_signal_received
    assert result.exit_signal == "/exit"
    assert result.iterations == 4

    assert Enum.map(result.submitted_tasks, & &1.task_input) == [
             "Recover after blank input"
           ]

    assert Enum.map(result.input_events, & &1.task_input) == [
             "Recover after blank input"
           ]

    assert_receive {:task_request, %{task_input: "Recover after blank input"},
                    %{status: :healthy}}

    refute_receive {:task_request, %{task_input: ""}, _startup_result}
    assert output =~ "task: queued"
    assert output =~ "exiting ourocode"
  end

  test "routes ooo interview prompt to the interview workflow without slash command dispatch" do
    parent = self()
    prompt = "ooo interview define ourocode MCP streamable UI requirements."
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

    assert output =~ "task: starting"
    assert output =~ "interview accepted"
    assert output =~ ~s(accepted "#{prompt}")
    refute output =~ "[workflow-starting]"
    refute output =~ "dispatching_input"

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

  test "reserved builtin commands are journaled through the command path and keep the loop alive" do
    journal_path = journal_path("terminal-reserved-builtins")

    {result, output} =
      capture_event_loop(
        %{status: :healthy},
        [
          "/clear\n",
          "/resume\n",
          "Recover after commands\n",
          "/exit\n"
        ],
        journal_path: journal_path
      )

    assert output =~ "task: queued"

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
    {result, output} =
      capture_event_loop(
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
        ["/help\n", "/capabilities\n", "/status\n", "/plugins\n", "/exit\n"],
        []
      )

    assert output =~ "start here:"
    assert output =~ "/help"
    refute output =~ "[builtin/discovery]"
    assert output =~ "capabilities:"
    assert output =~ "+-- State"
    assert output =~ "plugins: 1 available"
    assert output =~ "Guided workflows"
    refute output =~ "ouroboros-plugin"

    assert Enum.map(result.command_events, & &1.command) == [
             "/help",
             "/capabilities",
             "/status",
             "/plugins"
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

    assert output =~ "task: queued"
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

      assert [
               %{
                 task_input: "Summarize the focused child pane",
                 focused_pane: :children
               } = input_event
             ] = result.input_events

      refute Map.has_key?(input_event, :previous_focused_pane)
    end)

    assert_receive {:command, %{command: "/pane"}, ["children"], %{status: :healthy}}

    assert_receive {:prompt_routed, %{task_input: "Summarize the focused child pane"},
                    %{focused_pane: :children}, %{status: :healthy}}

    refute_receive {:prompt_routed, _task_request, %{focused_pane: :parent}, _startup_result}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, & &1.type) == [
             :slash_command_submitted,
             :focus_state_updated,
             :prompt_input_submitted
           ]

    assert %{focused_pane: "children"} = List.last(journaled)
  end

  test "routes prompt input to the concrete focused child pane steering target" do
    parent = self()
    child_pane_id = "child-session:steering-bravo"

    lines =
      start_lines([
        "/pane #{child_pane_id}\n",
        "transport must include stdio, SSE, and streamable HTTP.\n",
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

      assert [
               %{
                 focused_pane: ^child_pane_id,
                 steering_target_pane_id: ^child_pane_id,
                 steering_target_session_id: "steering-bravo"
               }
             ] = result.input_events
    end)

    assert_receive {:command, %{command: "/pane"}, [^child_pane_id], %{status: :healthy}}

    assert_receive {:prompt_routed,
                    %{task_input: "transport must include stdio, SSE, and streamable HTTP."},
                    %{
                      focused_pane: ^child_pane_id,
                      steering_target_pane_id: ^child_pane_id,
                      steering_target_session_id: "steering-bravo"
                    }, %{status: :healthy}}

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert %{type: :focus_state_updated, steering_target_pane_id: ^child_pane_id} =
             Enum.find(journaled, &(&1.type == :focus_state_updated))

    assert %{type: :prompt_input_submitted, steering_target_pane_id: ^child_pane_id} =
             Enum.find(journaled, &(&1.type == :prompt_input_submitted))
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

    {result, output} =
      capture_event_loop(
        %{status: :healthy},
        [
          "Summarize parent state from stdin\n",
          "Route child stream from stdin\n"
        ],
        on_task: fn task_request, startup_result ->
          send(parent, {:task_request, task_request, startup_result})
        end
      )

    assert result.status == :input_eof
    assert result.exit_signal == nil
    assert result.iterations == 2

    assert Enum.map(result.submitted_tasks, & &1.task_input) == [
             "Summarize parent state from stdin",
             "Route child stream from stdin"
           ]

    assert_receive {:task_request, %{task_input: "Summarize parent state from stdin"},
                    %{status: :healthy}}

    assert_receive {:task_request, %{task_input: "Route child stream from stdin"},
                    %{status: :healthy}}

    assert output =~ "task: queued"
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

    assert output =~ "plugins: 1 available"
    assert output =~ "[BUILT-IN] Guided workflows"
    assert output =~ "loaded"
    refute output =~ "ouroboros-plugin"
    assert output =~ "exiting ourocode"

    assert {:ok, journaled} = Journal.read_ordered(journal_path)

    assert Enum.map(journaled, &journaled_type/1) == [
             :plugin_config_reload_requested,
             :plugin_config_reloaded
           ]
  end

  defp start_lines(lines) do
    {:ok, pid} = Agent.start_link(fn -> lines end)
    pid
  end

  defp capture_event_loop(startup_result, lines, options \\ []) do
    ref = make_ref()
    lines = start_lines(lines)

    output =
      capture_io(fn ->
        options =
          options
          |> Map.new()
          |> Map.put(:read_line, next_line(lines))

        assert {:ok, result} = EventLoop.run(startup_result, options)
        send(self(), {ref, result})
      end)

    assert_receive {^ref, result}
    {result, output}
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
