defmodule Ourocode.Runtime.LoopBindingsTest do
  @moduledoc """
  Proves the live seam the interactive loop depends on: routed runtime events
  are drained by a monotonic cursor, folded into live parent/child pane state,
  and exposed to the renderer via `pane_snapshot/1`.

  Network transport is intentionally not exercised here; it shares the same
  `route_event` -> pipeline -> poll seam this test drives deterministically.
  """

  use ExUnit.Case, async: false

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.Runtime.Application
  alias Ourocode.Runtime.LoopBindings
  alias Ourocode.TaskRequest
  alias Ourocode.WonderTool.InteractionDetector

  setup do
    {:ok, runtime} =
      Application.bootstrap(%{
        project_dir: File.cwd!(),
        config: Ourocode.Config.defaults()
      })

    on_exit(fn -> Application.stop(runtime) end)
    %{runtime: runtime}
  end

  test "attach wires handlers and drains routed events into live panes", %{runtime: runtime} do
    assert {:ok, agent, options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    assert is_function(options[:on_prompt_input], 3)
    assert is_function(options[:poll_runtime_event], 1)
    assert is_function(options[:on_runtime_event], 2)

    poll = options[:poll_runtime_event]
    handle = options[:on_runtime_event]

    parent_call_id = "parent-loopbindings-1"

    parent_started =
      LifecycleEvent.new(:parent_call_started, %{
        event_seq: 1,
        transport: :streamable_http,
        parent_call_id: parent_call_id,
        runtime_source: "ouroboros",
        external_ids: %{session_id: "session-loopbindings-1"},
        occurred_at_ms: 1_000,
        request_id: "req-loopbindings",
        method: "tools/call"
      })

    # Transport relay ingests normalized events: panes fold immediately and
    # the loop poller still drains FIFO for bookkeeping.
    assert :ok == LoopBindings.enqueue(agent, parent_started)

    assert {:ok, drained} = poll.(%{})
    assert :none == poll.(%{})

    assert :ok == handle.(drained, %{})

    snapshot = LoopBindings.pane_snapshot(agent)

    assert %{runtime: %{parent_panes: parent, child_panes: child}} = snapshot
    assert is_map(child)

    assert [%{} | _] = parent.working
    assert parent.focused != nil

    rendered = Ourocode.Dashboard.ParentMcpPane.render(parent)
    assert [%{line: line} | _] = rendered.working
    assert line =~ "parent=#{parent_call_id}"
    assert line =~ "transport=streamable_http"
  end

  test "non-ouroboros prompt input is a no-op and never raises", %{runtime: runtime} do
    {:ok, _agent, options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    task_request = %Ourocode.TaskRequest{
      id: "plain-1",
      task_input: "just chatting",
      routing_decision: %{execution_route: :runtime, runtime_source: :auto, transport: :auto}
    }

    assert :ok == options[:on_prompt_input].(task_request, %{}, %{status: :healthy})
  end

  test "ooo interview prompt returns immediately and paints a pending transcript", %{
    runtime: runtime
  } do
    previous_autostart = System.get_env("OUROCODE_MCP_AUTOSTART")
    System.put_env("OUROCODE_MCP_AUTOSTART", "0")

    on_exit(fn ->
      if previous_autostart,
        do: System.put_env("OUROCODE_MCP_AUTOSTART", previous_autostart),
        else: System.delete_env("OUROCODE_MCP_AUTOSTART")
    end)

    {:ok, agent, options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})
    prompt = "ooo interview improve the onboarding flow"
    {:ok, task_request} = TaskRequest.parse(prompt, id: "fast-interview")

    input_event = %{
      input_kind: :natural_language,
      task_request_id: task_request.id,
      task_input: prompt
    }

    assert :ok == options[:on_prompt_input].(task_request, input_event, %{status: :healthy})

    snap = LoopBindings.pane_snapshot(agent)
    assert snap.interview.waiting == true
    assert snap.interview.status == "starting interview session"
    assert snap.interview_session.parent_call_id == "parent-fast-interview"
    assert [%{role: :user, text: ^prompt} | _] = snap.interview.dialogue
  end

  test "wonderTool checkpoint is detected live and answered back", %{runtime: runtime} do
    {:ok, agent, _options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    wonder_payload = %{
      "tool" => "wonderTool",
      "request_id" => "wt-1",
      "child_id" => "child-wt-1",
      "parent_call_id" => "parent-wt-1",
      "questions" => [
        %{
          "id" => "transport",
          "header" => "Transport",
          "question" => "Which MCP transport should the interview prioritize?",
          "options" => [
            %{"label" => "stdio", "description" => "local process pipe"},
            %{"label" => "streamable HTTP", "description" => "remote streaming"}
          ]
        }
      ]
    }

    assert :ok ==
             LoopBindings.enqueue(agent, %{
               type: :child_event,
               source: :ouroboros,
               payload: wonder_payload
             })

    snapshot = LoopBindings.pane_snapshot(agent)
    assert %{tool: :wonder_tool, question_count: 1} = snapshot.wonder_tool

    assert {:ok, decision} = LoopBindings.answer_wonder(agent, 2)
    assert decision.selected_label == "streamable HTTP"
    assert decision.question_id == "transport"

    # Overlay clears and the answer is folded back as a closing ack.
    assert LoopBindings.pane_snapshot(agent).wonder_tool == nil
    assert {:error, :no_active_wonder} = LoopBindings.answer_wonder(agent, 1)
  end

  test "wonderTool checkpoint can be cancelled without selecting an option", %{runtime: runtime} do
    {:ok, agent, options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    wonder_payload = %{
      "tool" => "wonderTool",
      "request_id" => "wt-cancel-1",
      "child_id" => "child-wt-cancel-1",
      "parent_call_id" => "parent-wt-cancel-1",
      "questions" => [
        %{
          "id" => "direction",
          "header" => "Direction",
          "question" => "Which direction should we take?",
          "options" => [
            %{"label" => "A", "description" => "first path"},
            %{"label" => "B", "description" => "second path"}
          ]
        }
      ]
    }

    assert :ok ==
             LoopBindings.enqueue(agent, %{
               type: :child_event,
               source: :ouroboros,
               payload: wonder_payload
             })

    assert %{tool: :wonder_tool} = LoopBindings.pane_snapshot(agent).wonder_tool

    assert {:ok, cancelled} = LoopBindings.cancel_wonder(agent, "decline")
    assert cancelled.cancelled == true
    assert cancelled.reason == "decline"
    assert cancelled.question_id == "direction"
    assert LoopBindings.pane_snapshot(agent).wonder_tool == nil

    poll = options[:poll_runtime_event]
    drained = drain_all(poll, [])

    assert Enum.any?(drained, fn event ->
             get_in(event, [:payload, :kind]) == :wonder_tool_cancelled and
               get_in(event, [:payload, :token]) == "declined: decline"
           end)

    assert {:error, :no_active_wonder} = LoopBindings.cancel_wonder(agent, "decline")
  end

  test "cancelling an interview wonder checkpoint completes the visible interview", %{
    runtime: runtime
  } do
    {:ok, agent, _options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})
    parent = self()

    wonder_payload = %{
      "tool" => "wonderTool",
      "request_id" => "wt-cancel-interview",
      "parent_call_id" => "parent-wt-cancel-interview",
      "questions" => [
        %{
          "id" => "direction",
          "header" => "Direction",
          "question" => "Which direction should we take?",
          "options" => [
            %{"label" => "Stop", "description" => "cancel it"},
            %{"label" => "Continue", "description" => "keep going"}
          ]
        }
      ]
    }

    assert {:ok, detection} = InteractionDetector.detect(wonder_payload)

    Agent.update(agent, fn state ->
      %{
        state
        | interview: %{
            parent_call_id: "parent-wt-cancel-interview",
            question: "Which direction should we take?",
            status: "waiting for your answer",
            waiting: false
          },
          interview_waiter: parent,
          wonder: detection
      }
    end)

    assert {:ok, _cancelled} = LoopBindings.cancel_wonder(agent, "cancel")
    assert_receive {:interview_answer, "cancel"}

    snap = LoopBindings.pane_snapshot(agent)
    assert snap.wonder_tool == nil
    assert snap.paused == false
    assert snap.interview.complete == :user_done
    assert snap.interview.waiting == false
  end

  test "cancel_interview immediately completes a waiting interview", %{runtime: runtime} do
    {:ok, agent, _options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})
    parent = self()

    Agent.update(agent, fn state ->
      %{
        state
        | interview: %{
            parent_call_id: "parent-cancel-interview",
            question: "Continue?",
            status: "waiting for your answer",
            waiting: true
          },
          interview_waiter: parent,
          paused: true
      }
    end)

    assert {:ok, "cancel"} = LoopBindings.cancel_interview(agent)
    assert_receive {:interview_answer, "cancel"}

    snap = LoopBindings.pane_snapshot(agent)
    assert snap.wonder_tool == nil
    assert snap.paused == false
    assert snap.interview.complete == :user_done
    assert snap.interview.waiting == false
  end

  test "cancel_interview prevents an in-flight round result from reviving the picker" do
    {:ok, agent} = LoopBindings.start_link()
    parent = self()

    pcf = fn payload ->
      send(parent, {:pcf_started, payload})

      receive do
        :release_round ->
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "(ambiguity: 0.80) Which signal proves success?"}
              ],
              "meta" => %{"session_id" => "iv-cancel-race"}
            }
          })
      after
        1_000 ->
          flunk("round release not received")
      end
    end

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-cancel-race",
          initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
          parent_call_fun: pcf,
          model: scripted_model(["ASK_USER Should not appear?"]),
          project_dir: File.cwd!()
        )

        send(parent, :loop_done)
      end)

    assert_receive {:pcf_started, _payload}, 1_000

    assert {:ok, "cancel"} = LoopBindings.cancel_interview(agent)
    send(loop, :release_round)
    assert_receive :loop_done, 1_000

    snap = LoopBindings.pane_snapshot(agent)
    assert snap.wonder_tool == nil
    assert snap.interview.complete == :user_done
    assert snap.interview.waiting == false
    refute snap.interview.question =~ "signal proves success"
  end

  test "active wonderTool state survives unrelated runtime reload focus and pane events", %{
    runtime: runtime
  } do
    {:ok, agent, _options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    assert :ok ==
             LoopBindings.enqueue(agent, %{
               type: :child_event,
               source: :ouroboros,
               payload: %{
                 "tool" => "wonderTool",
                 "request_id" => "wt-preserve-1",
                 "child_id" => "child-wt-preserve-1",
                 "parent_call_id" => "parent-wt-preserve-1",
                 "questions" => [
                   %{
                     "id" => "direction",
                     "header" => "Direction",
                     "question" => "Which direction should we take?",
                     "options" => [
                       %{"label" => "A", "description" => "first path"},
                       %{"label" => "B", "description" => "second path"}
                     ]
                   }
                 ]
               }
             })

    before = LoopBindings.pane_snapshot(agent).wonder_tool
    assert before.request.request_id == "wt-preserve-1"

    for event <- [
          %{type: :plugin_config_reloaded, event_type: :plugin_config_reloaded, status: :loaded},
          %{
            type: :focus_changed,
            event_type: :focus_changed,
            focused_pane: "child-session:other"
          },
          LifecycleEvent.new(:parent_call_started, %{
            event_seq: 44,
            transport: :streamable_http,
            parent_call_id: "parent-other",
            runtime_source: "ouroboros",
            external_ids: %{},
            occurred_at_ms: 2_000,
            request_id: "req-other",
            method: "tools/call"
          })
        ] do
      assert :ok == LoopBindings.enqueue(agent, event)
      assert LoopBindings.pane_snapshot(agent).wonder_tool.request.request_id == "wt-preserve-1"
    end
  end

  test "absorbs an Ouroboros capability graph into the merged registry", %{runtime: runtime} do
    tools = [
      %{"name" => "ouroboros_interview", "description" => "Socratic interview"},
      %{"name" => "ouroboros_seed", "description" => "Generate a Seed"},
      %{"bogus" => "no name"}
    ]

    assert {:ok, result} = LoopBindings.ingest_capabilities(runtime, tools)
    assert %{accepted_entries: accepted} = result

    text = inspect(accepted)
    assert text =~ "ouroboros" and text =~ "interview"
    assert text =~ "seed"
    # Only the two named tools are absorbed; the nameless descriptor is dropped.
    assert length(accepted) == 2

    assert {:ok, :no_capabilities} = LoopBindings.ingest_capabilities(runtime, [])
  end

  test "interview reasoning is extracted from the wire response", %{runtime: runtime} do
    {:ok, agent, _options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    # The MCP interview wire-encodes `(ambiguity: X) <question>` + structured meta.
    assert :ok ==
             LoopBindings.enqueue(agent, %{
               type: :child_event,
               source: :ouroboros,
               parent_call_id: "parent-iv-1",
               child_id: "child-iv-1",
               payload: %{
                 "token" => "(ambiguity: 0.42) What MCP transports must the baseline support?",
                 "meta" => %{
                   "milestone" => "scope",
                   "seed_ready" => false,
                   "session_id" => "iv-sess-1"
                 }
               }
             })

    snap = LoopBindings.pane_snapshot(agent)
    assert snap.interview.ambiguity == 0.42
    assert snap.interview.question =~ "What MCP transports"
    assert snap.interview.milestone == "scope"
    assert snap.interview.seed_ready == false
    assert snap.paused == false

    # Esc pauses without discarding the question; resume re-activates.
    assert :ok == LoopBindings.pause_wonder(agent)
    assert LoopBindings.pane_snapshot(agent).paused == true
    assert LoopBindings.pane_snapshot(agent).interview.question =~ "What MCP transports"
    assert :ok == LoopBindings.resume_wonder(agent)
    assert LoopBindings.pane_snapshot(agent).paused == false

    # Free-text answer is recorded and clears the pause.
    assert {:ok, "stdio, SSE, streamable HTTP"} =
             LoopBindings.answer_interview(agent, "stdio, SSE, streamable HTTP")

    assert LoopBindings.pane_snapshot(agent).interview.answered ==
             "stdio, SSE, streamable HTTP"

    assert {:error, :no_active_interview} ==
             LoopBindings.answer_interview(start_isolated_agent(), "x")
  end

  test "interview reasoning prefers structured MCP metadata", %{runtime: runtime} do
    {:ok, agent, _options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    assert :ok ==
             LoopBindings.enqueue(agent, %{
               type: :child_event,
               source: :ouroboros,
               parent_call_id: "parent-iv-meta-1",
               child_id: "child-iv-meta-1",
               payload: %{
                 "token" => "Which MCP transport should the UI prioritize?",
                 "meta" => %{
                   "session_id" => "iv-meta-1",
                   "ambiguity_score" => 0.31,
                   "milestone" => "scope",
                   "seed_ready" => false,
                   "internal_reasoning" => [
                     "phase: answer",
                     "rounds: 1 answered / 2 total",
                     "next: ask user to answer pending question"
                   ],
                   "interview_reasoning" => %{
                     "phase" => "answer",
                     "pending_question" => true,
                     "next_action" => "ask user to answer pending question"
                   }
                 }
               }
             })

    snap = LoopBindings.pane_snapshot(agent)

    assert snap.interview.question =~ "Which MCP transport"
    assert snap.interview.ambiguity == 0.31
    assert snap.interview.milestone == "scope"
    assert snap.interview.seed_ready == false
    assert snap.interview.session_id == "iv-meta-1"

    assert snap.interview.mcp_reasoning == [
             "phase: answer",
             "rounds: 1 answered / 2 total",
             "next: ask user to answer pending question"
           ]

    assert snap.interview.mcp_reasoning_state["phase"] == "answer"
  end

  test "interview reasoning is extracted from MCP result _meta", %{runtime: runtime} do
    {:ok, agent, _options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    assert :ok ==
             LoopBindings.enqueue(agent, %{
               type: :child_event,
               source: :ouroboros,
               parent_call_id: "parent-iv-meta-2",
               child_id: "child-iv-meta-2",
               payload: %{
                 "result" => %{
                   "content" => [
                     %{
                       "type" => "text",
                       "text" =>
                         "Interview started. Session ID: iv-meta-2\n\nWhich UX area should improve?"
                     }
                   ],
                   "_meta" => %{
                     "session_id" => "iv-meta-2",
                     "interview_reasoning" => %{
                       "phase" => "start",
                       "session_id" => "iv-meta-2",
                       "next_action" => "ask user to answer pending question",
                       "answered_rounds" => 0,
                       "total_rounds" => 1,
                       "pending_question" => true,
                       "is_brownfield" => false,
                       "ambiguity_score" => 0.64,
                       "milestone" => "scope",
                       "seed_ready" => false,
                       "completion_candidate_streak" => 0,
                       "streak_required" => 2,
                       "question_chars" => 33
                     }
                   }
                 }
               }
             })

    snap = LoopBindings.pane_snapshot(agent)

    assert snap.interview.question =~ "Which UX area should improve?"
    assert snap.interview.session_id == "iv-meta-2"

    assert snap.interview.mcp_reasoning == [
             "phase: start",
             "session: iv-meta-2",
             "rounds: 0 answered / 1 total",
             "pending: waiting for user answer",
             "brownfield: false",
             "ambiguity: 0.64",
             "milestone: scope",
             "seed-ready: false",
             "stability: 0/2",
             "question_chars: 33",
             "next: ask user to answer pending question"
           ]
  end

  test "pane snapshot tails Ouroboros activity into the interview state" do
    {:ok, agent} = LoopBindings.start_link()

    path =
      Path.join(System.tmp_dir!(), "ourocode-loop-log-#{System.unique_integer([:positive])}.log")

    on_exit(fn -> File.rm(path) end)

    File.write!(path, "")

    Agent.update(agent, fn state ->
      %{
        state
        | interview: %{status: "waiting for mcp follow-up question"},
          ouroboros_log_paths: [path],
          ouroboros_log_offsets: %{path => 0}
      }
    end)

    File.write!(
      path,
      "2026-05-21T18:56:42.260163Z [info     ] interview.question_generated filename=interview.py interview_id=interview_1 lineno=520 question_length=133 round_number=1\n"
    )

    snap = LoopBindings.pane_snapshot(agent)

    assert snap.interview.mcp_activity == [
             "round 1 · question generated · 133 chars"
           ]
  end

  test "pane snapshot falls back to persisted Ouroboros interview session state" do
    previous_ouroboros_home = System.get_env("OUROCODE_OUROBOROS_HOME")
    home = Path.join(System.tmp_dir!(), "ourocode-home-#{System.unique_integer([:positive])}")
    ouroboros_home = Path.join(home, ".ouroboros")
    File.mkdir_p!(Path.join([ouroboros_home, "data"]))
    System.put_env("OUROCODE_OUROBOROS_HOME", ouroboros_home)

    on_exit(fn ->
      if previous_ouroboros_home,
        do: System.put_env("OUROCODE_OUROBOROS_HOME", previous_ouroboros_home),
        else: System.delete_env("OUROCODE_OUROBOROS_HOME")

      File.rm_rf(home)
    end)

    {:ok, agent} = LoopBindings.start_link()

    File.write!(
      Path.join([ouroboros_home, "data", "interview_interview_snapshot.json"]),
      Ourocode.Json.encode!(%{
        "interview_id" => "interview_snapshot",
        "status" => "in_progress",
        "rounds" => [
          %{
            "round_number" => 1,
            "question" => "Which MCP state should the UI surface?",
            "user_response" => nil
          }
        ],
        "is_brownfield" => false,
        "completion_candidate_streak" => 0
      })
    )

    Agent.update(agent, fn state ->
      %{state | interview: %{session_id: "interview_snapshot", question: "Which MCP state?"}}
    end)

    snap = LoopBindings.pane_snapshot(agent)

    assert snap.interview.mcp_reasoning == [
             "phase: question",
             "session: interview_snapshot",
             "rounds: 0 answered / 1 total",
             "pending: waiting for user answer",
             "brownfield: false",
             "stability: 0",
             "status: in_progress",
             "question_chars: 38",
             "next: ask user to answer pending question",
             "source: session_state"
           ]

    assert snap.interview.mcp_reasoning_state["source"] == "session_state"
  end

  test "pane snapshot enriches activity lengths with persisted session text" do
    previous_ouroboros_home = System.get_env("OUROCODE_OUROBOROS_HOME")
    home = Path.join(System.tmp_dir!(), "ourocode-home-#{System.unique_integer([:positive])}")
    ouroboros_home = Path.join(home, ".ouroboros")
    log_path = Path.join(home, "ouroboros.log")
    File.mkdir_p!(Path.join([ouroboros_home, "data"]))
    System.put_env("OUROCODE_OUROBOROS_HOME", ouroboros_home)

    on_exit(fn ->
      if previous_ouroboros_home,
        do: System.put_env("OUROCODE_OUROBOROS_HOME", previous_ouroboros_home),
        else: System.delete_env("OUROCODE_OUROBOROS_HOME")

      File.rm_rf(home)
    end)

    File.write!(
      Path.join([ouroboros_home, "data", "interview_interview_activity.json"]),
      Ourocode.Json.encode!(%{
        "interview_id" => "interview_activity",
        "initial_context" => "ooo interview improve the right panel",
        "rounds" => [
          %{
            "round_number" => 1,
            "question" => "Which panel should surface the MCP reasoning?",
            "user_response" => nil
          }
        ],
        "is_brownfield" => true
      })
    )

    File.write!(
      log_path,
      [
        "2026-05-22T07:35:45Z [info     ] interview.started filename=interview.py initial_context_length=39 interview_id=interview_activity is_brownfield=True lineno=392\n",
        "2026-05-22T07:35:45Z [info     ] interview.started filename=interview.py initial_context_length=39 interview_id=interview_activity is_brownfield=True lineno=392\n",
        "2026-05-22T07:35:46Z [info     ] interview.question_generated filename=interview.py interview_id=interview_activity lineno=520 question_length=114 round_number=1\n"
      ]
    )

    {:ok, agent} = LoopBindings.start_link()

    Agent.update(agent, fn state ->
      %{
        state
        | interview: %{session_id: "interview_activity", question: "Which panel?"},
          ouroboros_log_paths: [log_path],
          ouroboros_log_offsets: %{log_path => 0}
      }
    end)

    snap = LoopBindings.pane_snapshot(agent)

    assert snap.interview.mcp_activity == [
             "interview started · session activity · brownfield · initial: ooo interview improve the right panel",
             "round 1 · question: Which panel should surface the MCP reasoning?"
           ]

    assert LoopBindings.pane_snapshot(agent).interview.mcp_activity == snap.interview.mcp_activity
  end

  test "MCP response meta reasoning takes precedence over persisted session fallback" do
    previous_ouroboros_home = System.get_env("OUROCODE_OUROBOROS_HOME")
    home = Path.join(System.tmp_dir!(), "ourocode-home-#{System.unique_integer([:positive])}")
    ouroboros_home = Path.join(home, ".ouroboros")
    File.mkdir_p!(Path.join([ouroboros_home, "data"]))
    System.put_env("OUROCODE_OUROBOROS_HOME", ouroboros_home)

    on_exit(fn ->
      if previous_ouroboros_home,
        do: System.put_env("OUROCODE_OUROBOROS_HOME", previous_ouroboros_home),
        else: System.delete_env("OUROCODE_OUROBOROS_HOME")

      File.rm_rf(home)
    end)

    {:ok, agent} = LoopBindings.start_link()

    File.write!(
      Path.join([ouroboros_home, "data", "interview_interview_snapshot.json"]),
      Ourocode.Json.encode!(%{
        "interview_id" => "interview_snapshot",
        "status" => "in_progress",
        "rounds" => [
          %{"round_number" => 1, "question" => "Fallback question?", "user_response" => nil}
        ],
        "is_brownfield" => false
      })
    )

    Agent.update(agent, fn state ->
      %{
        state
        | interview: %{
            session_id: "interview_snapshot",
            mcp_reasoning: ["phase: start", "source: response_meta"]
          }
      }
    end)

    snap = LoopBindings.pane_snapshot(agent)

    assert snap.interview.mcp_reasoning == ["phase: start", "source: response_meta"]
  end

  test "interview session loop: question → ANSWER → followup → seed-ready" do
    {:ok, agent} = LoopBindings.start_link()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "(ambiguity: 0.50) What language is this project?"}
              ],
              "meta" => %{"session_id" => "iv-1"}
            }
          }),
          parent_result(%{
            "result" => %{
              "content" => [%{"type" => "text", "text" => "(ambiguity: 0.10) 📍 Next: ooo seed"}]
            }
          })
        ]
      end)

    pcf = fn _payload ->
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    model = scripted_model(["ANSWER [from-code] Elixir 1.15, escript CLI (mix.exs)"])

    assert :ok ==
             LoopBindings.run_interview_session(agent,
               parent_call_id: "parent-iv-loop",
               initial_payload: %{
                 "params" => %{"name" => "ouroboros_interview", "arguments" => %{}}
               },
               parent_call_fun: pcf,
               model: model,
               project_dir: File.cwd!()
             )

    snap = LoopBindings.pane_snapshot(agent)
    assert snap.interview.seed_ready == true
    assert snap.interview.complete == :seed_ready
    assert [_ | _] = snap.interview.router
    assert Enum.any?(snap.interview.router, &(&1 =~ "ANSWER [code]"))
  end

  test "interview session transcript starts with the user's original prompt" do
    {:ok, agent} = LoopBindings.start_link()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "What change should this interview define?"}
              ],
              "meta" => %{"session_id" => "iv-user-first"}
            }
          }),
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => "📍 Next: ooo seed"}]}
          })
        ]
      end)

    pcf = fn _payload ->
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    prompt = "ooo interview improve the ourocode interview UX"
    test_pid = self()

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-user-first",
          initial_payload: %{
            "params" => %{
              "name" => "ouroboros_interview",
              "arguments" => %{"initial_context" => prompt}
            }
          },
          parent_call_fun: pcf,
          model: scripted_model(["ASK_USER Which UX should improve?"]),
          project_dir: File.cwd!()
        )

        send(test_pid, :user_first_loop_done)
      end)

    wait_for(fn ->
      iv = LoopBindings.pane_snapshot(agent).interview
      iv && iv.question =~ "Which UX should improve?"
    end)

    snap = LoopBindings.pane_snapshot(agent)
    assert Enum.map(snap.interview.dialogue, & &1.role) |> Enum.reverse() == [:user, :mcp, :main]
    assert List.last(Enum.reverse(snap.interview.dialogue)).text =~ "Which UX should improve?"
    assert Enum.reverse(snap.interview.dialogue) |> hd() |> Map.fetch!(:text) == prompt

    assert {:ok, "Developer workflow"} =
             LoopBindings.answer_interview(agent, "Developer workflow")

    assert_receive :user_first_loop_done, 1_000
    assert Process.alive?(loop) == false
  end

  test "interview session shows waiting state while MCP is generating a question" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    pcf = fn payload ->
      send(test_pid, {:pcf_waiting, payload})

      receive do
        :release_pcf ->
          {:ok,
           parent_result(%{
             "result" => %{
               "content" => [%{"type" => "text", "text" => "📍 Next: ooo seed"}]
             }
           })}
      end
    end

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-waiting",
          initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
          parent_call_fun: pcf,
          model: scripted_model([]),
          project_dir: File.cwd!()
        )

        send(test_pid, :waiting_loop_done)
      end)

    assert_receive {:pcf_waiting, _initial}, 1_000

    snap = LoopBindings.pane_snapshot(agent)
    assert snap.interview.waiting == true
    assert snap.interview.status == "waiting for MCP interview question"
    assert snap.interview_session.status == "waiting for MCP interview question"

    send(loop, :release_pcf)
    assert_receive :waiting_loop_done, 1_000
  end

  test "pm interview shows an immediate local picker while the first MCP question is loading" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    pcf = fn payload ->
      send(test_pid, {:pcf_waiting, payload})

      receive do
        :release_pcf ->
          {:ok,
           parent_result(%{
             "result" => %{
               "content" => [
                 %{"type" => "text", "text" => "(ambiguity: 0.80) What outcome should we define?"}
               ],
               "meta" => %{"session_id" => "iv-fast-1"}
             }
           })}
      end
    end

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-fast-picker",
          initial_payload: %{
            "params" => %{
              "name" => "ouroboros_interview",
              "arguments" => %{"initial_context" => "ooo pm build onboarding"}
            }
          },
          parent_call_fun: pcf,
          model: scripted_model([]),
          project_dir: File.cwd!()
        )

        send(test_pid, :fast_picker_loop_done)
      end)

    assert_receive {:pcf_waiting, _initial}, 1_000

    wait_for(fn ->
      snap = LoopBindings.pane_snapshot(agent)
      snap.wonder_tool && snap.interview && snap.interview.status == "waiting for your answer"
    end)

    snap = LoopBindings.pane_snapshot(agent)
    assert snap.interview.question =~ "What outcome should this PM interview produce"

    assert Enum.map(snap.interview.question_options, & &1["label"]) == [
             "Define the target user",
             "Define the activation outcome",
             "Audit the existing flow"
           ]

    assert {:ok, _cancelled} = LoopBindings.cancel_wonder(agent, "cancel")
    assert_receive :fast_picker_loop_done, 1_000
    assert Process.alive?(loop) == false
  end

  test "pm interview followup waits for the user instead of auto-routing another answer" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    initial_response =
      parent_result(%{
        "result" => %{
          "content" => [
            %{"type" => "text", "text" => "(ambiguity: 0.80) What outcome should we define?"}
          ],
          "meta" => %{"session_id" => "iv-fast-user-routed"}
        }
      })

    followup_response =
      parent_result(%{
        "result" => %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                "(ambiguity: 0.70) Which user segment should this onboarding primarily serve?"
            }
          ],
          "meta" => %{"session_id" => "iv-fast-user-routed"}
        }
      })

    pcf = fn payload ->
      send(test_pid, {:pcf_waiting, self(), payload})

      receive do
        {:release_pcf, response} -> {:ok, response}
      end
    end

    model = scripted_model(["ANSWER [from-code] experienced developers"])

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-fast-user-routed",
          initial_payload: %{
            "params" => %{
              "name" => "ouroboros_interview",
              "arguments" => %{"initial_context" => "ooo pm build onboarding"}
            }
          },
          parent_call_fun: pcf,
          model: model,
          project_dir: File.cwd!()
        )

        send(test_pid, :fast_user_routed_loop_done)
      end)

    assert_receive {:pcf_waiting, initial_pcf_pid, _initial}, 1_000

    wait_for(fn ->
      snap = LoopBindings.pane_snapshot(agent)
      snap.interview && snap.interview.question =~ "What outcome should this PM interview produce"
    end)

    assert {:ok, _decision} = LoopBindings.answer_wonder(agent, 1)
    send(initial_pcf_pid, {:release_pcf, initial_response})

    assert_receive {:pcf_waiting, followup_pcf_pid, followup_payload}, 1_000
    assert followup_payload["params"]["arguments"]["answer"] =~ "Define the target user"

    snap = LoopBindings.pane_snapshot(agent)
    refute snap.interview.question =~ "What outcome should we define?"
    assert snap.interview.status == "preparing next interview question"
    assert snap.interview.last_answer =~ "Define the target user"

    send(followup_pcf_pid, {:release_pcf, followup_response})

    wait_for(fn ->
      iv = LoopBindings.pane_snapshot(agent).interview
      (iv && iv.question =~ "Which user segment") and iv.status == "waiting for your answer"
    end)

    refute_receive {:pcf_waiting, _pid, _unexpected_auto_followup}, 200

    assert {:ok, _cancelled} = LoopBindings.cancel_wonder(agent, "cancel")
    assert_receive :fast_user_routed_loop_done, 1_000
    assert Process.alive?(loop) == false
  end

  test "user-routed followup asks main session to generate answer choices" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "(ambiguity: 0.80) Which scope should we pick?"}
              ],
              "meta" => %{"session_id" => "iv-main-options"}
            }
          }),
          parent_result(%{
            "result" => %{
              "content" => [
                %{
                  "type" => "text",
                  "text" => "(ambiguity: 0.70) 이번 라운드는 질문/답변 반영이 잘 되는지 검증하면 될까요?"
                }
              ],
              "meta" => %{"session_id" => "iv-main-options"}
            }
          })
        ]
      end)

    pcf = fn payload ->
      send(test_pid, {:followup, payload})
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    model =
      scripted_model([
        """
        ASK_USER Which scope should we pick?
        - Narrow fix | Target one concrete bug first
        - Broader UX | Improve the whole interview surface
        """,
        """
        - 질문이 이어진다 | 답변 뒤 다음 질문과 선택지가 생성되는지 확인
        - 답변이 반영된다 | 이전 답변이 다음 질문 문맥에 반영되는지 확인
        """
      ])

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-main-option-generator",
          initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
          parent_call_fun: pcf,
          model: model,
          project_dir: File.cwd!()
        )
      end)

    assert_receive {:followup, _initial}, 1_000

    wait_for(fn ->
      iv = LoopBindings.pane_snapshot(agent).interview
      iv && iv.question =~ "Which scope"
    end)

    assert {:ok, decision} = LoopBindings.answer_wonder(agent, 1)
    assert decision.selected_label == "Narrow fix"

    assert_receive {:followup, followup}, 1_000
    assert followup["params"]["arguments"]["answer"] =~ "[from-user] Narrow fix"

    wait_for(fn ->
      iv = LoopBindings.pane_snapshot(agent).interview
      (iv && iv.question =~ "질문/답변 반영") and Map.has_key?(iv, :question_options)
    end)

    snap = LoopBindings.pane_snapshot(agent)

    assert Enum.map(snap.interview.question_options, & &1["label"]) == [
             "질문이 이어진다",
             "답변이 반영된다"
           ]

    assert Enum.any?(
             snap.interview.router,
             &String.contains?(&1, "main session generated 2 answer choices")
           )

    assert {:ok, _cancelled} = LoopBindings.cancel_wonder(agent, "cancel")
    Process.exit(loop, :kill)
  end

  test "interview session loop: ASK_USER routes to answer_interview handoff" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "(ambiguity: 0.80) Which payment provider?"}
              ],
              "meta" => %{"session_id" => "iv-ask-1"}
            }
          }),
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => "📍 Next: ooo seed"}]}
          })
        ]
      end)

    pcf = fn payload ->
      send(test_pid, {:followup, payload})
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    # The router never auto-answers a human-judgment question.
    model = scripted_model(["ASK_USER Which payment provider should we integrate?"])

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-iv-ask",
          initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
          parent_call_fun: pcf,
          model: model,
          project_dir: File.cwd!()
        )

        send(test_pid, :loop_done)
      end)

    # First parent call is the initial one.
    assert_receive {:followup, _initial}, 1_000

    # The loop is now blocked on the ASK_USER routing decision; the question
    # is pinned and a waiter is registered.
    wait_for(fn ->
      iv = LoopBindings.pane_snapshot(agent).interview
      (iv && iv.question =~ "payment provider") and iv.status == "waiting for your answer"
    end)

    iv = LoopBindings.pane_snapshot(agent).interview
    assert iv.waiting == false
    assert iv.status == "waiting for your answer"

    assert {:ok, "Stripe"} = LoopBindings.answer_interview(agent, "Stripe")

    # The user's answer is forwarded to MCP with the [from-user] prefix.
    assert_receive {:followup, followup}, 1_000
    assert followup["params"]["arguments"]["session_id"] == "iv-ask-1"
    assert followup["params"]["arguments"]["answer"] =~ "[from-user] Stripe"

    assert_receive :loop_done, 1_000
    assert Process.alive?(loop) == false

    assert LoopBindings.pane_snapshot(agent).interview.complete == :seed_ready
  end

  test "interview session loop refines long user answers before MCP handoff" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "(ambiguity: 0.80) Which payment provider?"}
              ],
              "meta" => %{"session_id" => "iv-refine-1"}
            }
          }),
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => "📍 Next: ooo seed"}]}
          })
        ]
      end)

    pcf = fn payload ->
      send(test_pid, {:followup, payload})
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    model = scripted_model(["ASK_USER Which payment provider should we integrate?"])

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-iv-refine",
          initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
          parent_call_fun: pcf,
          model: model,
          project_dir: File.cwd!()
        )

        send(test_pid, :loop_done)
      end)

    assert_receive {:followup, _initial}, 1_000

    wait_for(fn ->
      iv = LoopBindings.pane_snapshot(agent).interview
      iv && iv.question =~ "payment provider"
    end)

    assert {:ok, _answer} =
             LoopBindings.answer_interview(
               agent,
               "Use Stripe because subscriptions are the core business model, but leave refunds out of scope."
             )

    wait_for(fn ->
      wt = LoopBindings.pane_snapshot(agent).wonder_tool

      if wt do
        wt.request.questions
        |> hd()
        |> Map.get(:question)
        |> String.contains?("structured")
      else
        false
      end
    end)

    assert {:ok, decision} = LoopBindings.answer_wonder(agent, 1)
    assert decision.selected_label == "Send as-is"

    assert_receive {:followup, followup}, 1_000
    answer = followup["params"]["arguments"]["answer"]

    assert answer =~ "[from-user][refined]"
    assert answer =~ "Decision:"
    assert answer =~ "Reasoning:"
    assert answer =~ "Out of scope (user-stated):"
    assert answer =~ "refunds out of scope"

    assert_receive :loop_done, 1_000
    assert Process.alive?(loop) == false
  end

  test "interview session loop: slow router falls back to user question" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    pcf = fn payload ->
      send(test_pid, {:followup, payload})

      {:ok,
       parent_result(%{
         "result" => %{
           "content" => [
             %{
               "type" => "text",
               "text" => "(ambiguity: 0.80) Which audience should we serve first?"
             }
           ],
           "meta" => %{"session_id" => "iv-timeout-1"}
         }
       })}
    end

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-timeout",
          initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
          parent_call_fun: pcf,
          model: hanging_model(),
          project_dir: File.cwd!(),
          router_decision_timeout_ms: 20
        )

        send(test_pid, :loop_done)
      end)

    assert_receive {:followup, _initial}, 1_000

    wait_for(fn ->
      wt = LoopBindings.pane_snapshot(agent).wonder_tool
      wt && wt.question_count == 1
    end)

    snap = LoopBindings.pane_snapshot(agent)
    assert snap.interview.question =~ "audience"
    assert Enum.any?(snap.interview.router, &String.contains?(&1, "router timeout"))

    assert {:ok, decision} = LoopBindings.answer_wonder(agent, 1)
    assert decision.selected_label == "Clarify the first priority"

    assert_receive {:followup, followup}, 1_000
    assert followup["params"]["arguments"]["session_id"] == "iv-timeout-1"
    assert followup["params"]["arguments"]["answer"] =~ "[from-user] Clarify the first priority"

    refute_receive :loop_done, 50
    assert Process.alive?(loop)
    Process.exit(loop, :kill)
  end

  test "interview fallback wonderTool derives choices from candidate axes in the question" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    pcf = fn payload ->
      send(test_pid, {:followup, payload})

      {:ok,
       parent_result(%{
         "result" => %{
           "content" => [
             %{
               "type" => "text",
               "text" =>
                 "Interview started. Session ID: iv-candidates-1\n\nWhich UX area should improve first? CLI flow, error messages, onboarding, result display"
             }
           ],
           "meta" => %{"session_id" => "iv-candidates-1"}
         }
       })}
    end

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-candidates",
          initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
          parent_call_fun: pcf,
          model: hanging_model(),
          project_dir: File.cwd!(),
          router_decision_timeout_ms: 20
        )
      end)

    assert_receive {:followup, _initial}, 1_000

    wait_for(fn ->
      wt = LoopBindings.pane_snapshot(agent).wonder_tool
      wt && wt.question_count == 1
    end)

    [%{options: options}] = LoopBindings.pane_snapshot(agent).wonder_tool.request.questions
    labels = Enum.map(options, & &1.label)

    assert labels == ["CLI flow", "error messages", "onboarding", "result display"]
    assert LoopBindings.pane_snapshot(agent).interview.question =~ "Which UX area"
    refute LoopBindings.pane_snapshot(agent).interview.question =~ "Interview started"

    Process.exit(loop, :kill)
  end

  test "interview fallback wonderTool handles candidate axes before a trailing question mark" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    pcf = fn payload ->
      send(test_pid, {:followup, payload})

      {:ok,
       parent_result(%{
         "result" => %{
           "content" => [
             %{
               "type" => "text",
               "text" =>
                 "What should improve? CLI flow, error messages, setup onboarding, result display, or another workflow?"
             }
           ],
           "meta" => %{"session_id" => "iv-ko-candidates-1"}
         }
       })}
    end

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-ko-candidates",
          initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
          parent_call_fun: pcf,
          model: hanging_model(),
          project_dir: File.cwd!(),
          router_decision_timeout_ms: 20
        )
      end)

    assert_receive {:followup, _initial}, 1_000

    wait_for(fn ->
      wt = LoopBindings.pane_snapshot(agent).wonder_tool
      wt && wt.question_count == 1
    end)

    [%{options: options}] = LoopBindings.pane_snapshot(agent).wonder_tool.request.questions
    labels = Enum.map(options, & &1.label)

    assert labels == ["CLI flow", "error messages", "setup onboarding", "result display"]

    Process.exit(loop, :kill)
  end

  test "interview session loop: ASK_USER becomes a wonderTool, answer_wonder hands back" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "(ambiguity: 0.80) Which payment provider?"}
              ],
              "meta" => %{"session_id" => "iv-wt-1"}
            }
          }),
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => "📍 Next: ooo seed"}]}
          })
        ]
      end)

    pcf = fn payload ->
      send(test_pid, {:followup, payload})
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    model =
      scripted_model([
        "ASK_USER Which payment provider?\n- Stripe | USD-first subscription tooling\n- Toss | KRW-native for Korean MAU"
      ])

    spawn(fn ->
      LoopBindings.run_interview_session(agent,
        parent_call_id: "parent-wt",
        initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
        parent_call_fun: pcf,
        model: model,
        project_dir: File.cwd!()
      )

      send(test_pid, :loop_done)
    end)

    assert_receive {:followup, _initial}, 1_000

    # The ASK_USER was synthesized into a wonderTool checkpoint with the
    # model's options.
    wait_for(fn ->
      wt = LoopBindings.pane_snapshot(agent).wonder_tool
      wt && wt.question_count == 1
    end)

    snap = LoopBindings.pane_snapshot(agent)
    assert %{tool: :wonder_tool} = snap.wonder_tool
    assert snap.interview.question =~ "payment provider"
    assert Enum.map(snap.interview.question_options, & &1["label"]) == ["Stripe", "Toss"]

    # Picking option 1 hands the chosen label back to the blocked relay.
    assert {:ok, decision} = LoopBindings.answer_wonder(agent, 1)
    assert decision.selected_label == "Stripe"

    assert_receive {:followup, followup}, 1_000
    assert followup["params"]["arguments"]["session_id"] == "iv-wt-1"
    assert followup["params"]["arguments"]["answer"] =~ "[from-user] Stripe"

    assert_receive :loop_done, 1_000
    assert LoopBindings.pane_snapshot(agent).interview.complete == :seed_ready
  end

  test "interview session loop asks the model for options when ASK_USER has none" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    pcf = fn payload ->
      send(test_pid, {:followup, payload})

      {:ok,
       parent_result(%{
         "result" => %{
           "content" => [
             %{
               "type" => "text",
               "text" =>
                 "Interview started. Session ID: iv-generated-options-1\n\nWhat is the bug's observable failure from a user or system perspective, and what behavior should replace it when the fix is correct?"
             }
           ],
           "meta" => %{"session_id" => "iv-generated-options-1"}
         }
       })}
    end

    model =
      scripted_model([
        "ASK_USER What failure and replacement behavior should the bug fix define?",
        """
        - User-visible failure | Describe the current broken behavior users or systems observe
        - Correct replacement | Describe the behavior that should happen after the fix
        - Evidence of fix | Name the signal that proves the fix works
        """
      ])

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-generated-options",
          initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
          parent_call_fun: pcf,
          model: model,
          project_dir: File.cwd!()
        )
      end)

    assert_receive {:followup, _initial}, 1_000

    wait_for(fn ->
      wt = LoopBindings.pane_snapshot(agent).wonder_tool
      wt && wt.question_count == 1
    end)

    snap = LoopBindings.pane_snapshot(agent)
    labels = Enum.map(snap.interview.question_options, & &1["label"])

    assert labels == ["User-visible failure", "Correct replacement", "Evidence of fix"]
    refute "Define the desired outcome" in labels
    refute "Clarify the target user" in labels

    Process.exit(loop, :kill)
  end

  test "interview session loop summarizes oversized initial context back to MCP" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    long_context =
      "ooo interview " <> String.duplicate("very detailed scope and constraints ", 20)

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "Please summarize the initial context."}
              ],
              "meta" => %{
                "session_id" => "iv-large-context-1",
                "reason" => "initial_context_too_large",
                "recoverable" => true,
                "max_chars" => 120
              }
            }
          }),
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => "📍 Next: ooo seed"}]}
          })
        ]
      end)

    pcf = fn payload ->
      send(test_pid, {:followup, payload})
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    spawn(fn ->
      LoopBindings.run_interview_session(agent,
        parent_call_id: "parent-large-context",
        initial_payload: %{
          "params" => %{
            "name" => "ouroboros_interview",
            "arguments" => %{"initial_context" => long_context}
          }
        },
        parent_call_fun: pcf,
        model: hanging_model(),
        project_dir: File.cwd!()
      )

      send(test_pid, :loop_done)
    end)

    assert_receive {:followup, _initial}, 1_000
    assert_receive {:followup, followup}, 1_000

    args = followup["params"]["arguments"]
    assert args["session_id"] == "iv-large-context-1"
    assert args["answer"] =~ "[from-user] ooo interview"
    assert String.length(String.replace_prefix(args["answer"], "[from-user] ", "")) <= 120

    assert_receive :loop_done, 1_000
  end

  test "answer_wonder: a multi-question checkpoint captures every question in order" do
    {:ok, agent} = LoopBindings.start_link()

    LoopBindings.enqueue(agent, %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: "p-multi",
      runtime_source: "ouroboros",
      occurred_at_ms: 0,
      payload: %{
        "tool" => "wonderTool",
        "request_id" => "p-multi-ask-1",
        "parent_call_id" => "p-multi",
        "questions" => [
          %{
            "id" => "transport",
            "header" => "Transport",
            "question" => "Which transport?",
            "options" => [
              %{"label" => "stdio", "description" => "local pipe"},
              %{"label" => "http", "description" => "remote stream"}
            ]
          },
          %{
            "id" => "scope",
            "header" => "Scope",
            "question" => "Which scope?",
            "options" => [
              %{"label" => "narrow", "description" => "one feature"},
              %{"label" => "broad", "description" => "whole module"}
            ]
          }
        ]
      }
    })

    assert LoopBindings.pane_snapshot(agent).wonder_tool.question_count == 2

    # One selection per question, in question order (1-based, like the TUI).
    assert {:ok, decision} = LoopBindings.answer_wonder(agent, [1, 2])
    assert decision.selected_label == "stdio; broad"
    assert length(decision.decisions) == 2
    assert Enum.map(decision.decisions, & &1.question_id) == ["transport", "scope"]
    assert Enum.map(decision.decisions, & &1.selected_label) == ["stdio", "broad"]

    # The checkpoint is closed and a combined ack reaches the child stream.
    assert is_nil(LoopBindings.pane_snapshot(agent).wonder_tool)
  end

  test "answer_wonder: a single-element list collapses to the legacy single answer" do
    {:ok, agent} = LoopBindings.start_link()

    LoopBindings.enqueue(agent, %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: "p-one",
      runtime_source: "ouroboros",
      occurred_at_ms: 0,
      payload: %{
        "tool" => "wonderTool",
        "request_id" => "p-one-ask-1",
        "parent_call_id" => "p-one",
        "questions" => [
          %{
            "id" => "transport",
            "header" => "Transport",
            "question" => "Which transport?",
            "options" => [
              %{"label" => "stdio", "description" => "local pipe"},
              %{"label" => "http", "description" => "remote stream"}
            ]
          }
        ]
      }
    })

    assert {:ok, decision} = LoopBindings.answer_wonder(agent, [2])
    assert decision.selected_label == "http"
    refute Map.has_key?(decision, :decisions)
  end

  test "answer_wonder: free text closes the checkpoint and records the answer" do
    {:ok, agent} = LoopBindings.start_link()

    LoopBindings.enqueue(agent, %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: "p-free",
      runtime_source: "ouroboros",
      occurred_at_ms: 0,
      payload: %{
        "tool" => "wonderTool",
        "request_id" => "p-free-ask-1",
        "parent_call_id" => "p-free",
        "questions" => [
          %{
            "id" => "ux_direction",
            "header" => "UX",
            "question" => "What should change?",
            "options" => [
              %{"label" => "Rendering", "description" => "question layout"},
              %{"label" => "Speed", "description" => "turn latency"}
            ]
          }
        ]
      }
    })

    assert %{tool: :wonder_tool} = LoopBindings.pane_snapshot(agent).wonder_tool

    assert {:ok, decision} =
             LoopBindings.answer_wonder(agent, %{"freeText" => "UX expert subagent consult"})

    assert decision.selected_label == "UX expert subagent consult"
    assert decision.free_text == "UX expert subagent consult"
    assert LoopBindings.pane_snapshot(agent).wonder_tool == nil
  end

  test "answer_wonder: free text can target a later multi-question id" do
    {:ok, agent} = LoopBindings.start_link()

    LoopBindings.enqueue(agent, %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: "p-free-multi",
      runtime_source: "ouroboros",
      occurred_at_ms: 0,
      payload: %{
        "tool" => "wonderTool",
        "request_id" => "p-free-multi-ask-1",
        "parent_call_id" => "p-free-multi",
        "questions" => [
          %{
            "id" => "transport",
            "header" => "Transport",
            "question" => "Which transport?",
            "options" => [
              %{"label" => "stdio", "description" => "local pipe"},
              %{"label" => "http", "description" => "remote stream"}
            ]
          },
          %{
            "id" => "scope",
            "header" => "Scope",
            "question" => "Which scope?",
            "options" => [
              %{"label" => "narrow", "description" => "one feature"},
              %{"label" => "broad", "description" => "whole module"}
            ]
          }
        ]
      }
    })

    assert {:ok, decision} =
             LoopBindings.answer_wonder(agent, %{
               "questionId" => "scope",
               "freeText" => "whole module with migration tests"
             })

    assert decision.question_id == "scope"
    assert decision.free_text == "whole module with migration tests"
    assert LoopBindings.pane_snapshot(agent).wonder_tool == nil
  end

  test "answer_wonder: multi-select single question preserves all selected options" do
    {:ok, agent} = LoopBindings.start_link()

    LoopBindings.enqueue(agent, %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: "p-multi-select",
      runtime_source: "ouroboros",
      occurred_at_ms: 0,
      payload: %{
        "tool" => "wonderTool",
        "request_id" => "p-multi-select-ask-1",
        "parent_call_id" => "p-multi-select",
        "questions" => [
          %{
            "id" => "growth_axes",
            "header" => "Growth",
            "question" => "Which axes?",
            "multiSelect" => true,
            "options" => [
              %{"label" => "Users", "description" => "grow adoption"},
              %{"label" => "Features", "description" => "complete core"},
              %{"label" => "Business", "description" => "make sustainable"}
            ]
          }
        ]
      }
    })

    assert {:ok, decision} = LoopBindings.answer_wonder(agent, [1, 3])
    assert decision.multi_select? == true
    assert decision.selected_indices == [1, 3]
    assert decision.selected_label == "Users, Business"
  end

  test "the three-party dialogue log records MCP/MAIN turns with ambiguity + prefix" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "(ambiguity: 0.80) Which payment provider?"}
              ],
              "meta" => %{"session_id" => "iv-dlg-1"}
            }
          }),
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => "📍 Next: ooo seed"}]}
          })
        ]
      end)

    pcf = fn payload ->
      send(test_pid, {:followup, payload})
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    # The answerer commits a code-derived fact (no user turn needed).
    model = scripted_model(["ANSWER [from-code] Stripe is already wired (lib/pay.ex)"])

    spawn(fn ->
      LoopBindings.run_interview_session(agent,
        parent_call_id: "parent-dlg",
        initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
        parent_call_fun: pcf,
        model: model,
        project_dir: File.cwd!()
      )

      send(test_pid, :loop_done)
    end)

    assert_receive :loop_done, 2_000

    dialogue =
      LoopBindings.pane_snapshot(agent).interview.dialogue
      |> Enum.reverse()
      |> Enum.map(&{&1.role, &1.text})

    assert dialogue == [
             {:mcp, "(ambiguity 0.80) Which payment provider?"},
             {:main, "[from-code] Stripe is already wired (lib/pay.ex)"},
             {:mcp, "interview complete (seed_ready) — next: ooo seed"}
           ]
  end

  test "interview session loop: user 'cancel' ends the session cleanly" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [%{"type" => "text", "text" => "(ambiguity: 0.90) What is the goal?"}],
              "meta" => %{"session_id" => "iv-cancel"}
            }
          })
        ]
      end)

    pcf = fn _payload -> {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)} end
    model = scripted_model(["ASK_USER What is the goal of this work?"])

    spawn(fn ->
      LoopBindings.run_interview_session(agent,
        parent_call_id: "parent-iv-cancel",
        initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
        parent_call_fun: pcf,
        model: model,
        project_dir: File.cwd!()
      )

      send(test_pid, :loop_done)
    end)

    wait_for(fn ->
      iv = LoopBindings.pane_snapshot(agent).interview
      iv && iv.question =~ "goal"
    end)

    assert {:ok, "cancel"} = LoopBindings.answer_interview(agent, "cancel")
    assert_receive :loop_done, 1_000
    assert LoopBindings.pane_snapshot(agent).interview.complete == :user_done
  end

  # Verbatim wire text captured from the live Ouroboros MCP server when its
  # clarification backend (gpt-5.5 via cliproxy) is down. FastMCP delivers
  # this server-side failure as `isError:false` + a "Question generation
  # failed: …" body — so it must be classified by text, not meta/isError.
  @real_502_text "Question generation failed: unexpected status 502 Bad Gateway: unknown provider for model gpt-5.5, url: https://cliproxy.zep.works/v1/responses (details: {'returncode': 1}). Session ID: interview_20260517_033303\n\nResume with: session_id=\"interview_20260517_033303\""

  test "interview loop: a server question-generation failure is surfaced, not routed as a question" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => @real_502_text}]}
          })
        ]
      end)

    pcf = fn payload ->
      send(test_pid, {:pcf, payload})
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    # If the failure body were misrouted as a question this model would run.
    model =
      scripted_model(["ANSWER [from-code] this must never be sent — the loop must stop"])

    assert :ok ==
             LoopBindings.run_interview_session(agent,
               parent_call_id: "parent-502",
               initial_payload: %{
                 "params" => %{"name" => "ouroboros_interview", "arguments" => %{}}
               },
               parent_call_fun: pcf,
               model: model,
               project_dir: File.cwd!()
             )

    # Exactly one MCP call (the initial). No followup turn was sent.
    assert_receive {:pcf, _initial}
    refute_received {:pcf, _followup}

    iv = LoopBindings.pane_snapshot(agent).interview
    assert iv.status =~ "MCP question generator unavailable"
    assert iv.status =~ "502"
    # session id is recovered from the failure text so the run is resumable.
    assert iv.session_id == "interview_20260517_033303"
    assert iv.resumable == true
  end

  test "interview loop: real Ouroboros completion text ends the session" do
    {:ok, agent} = LoopBindings.start_link()

    completion =
      "Interview completed. Session ID: interview_x\n\n(ambiguity: 0.15) Ready for Seed generation.\nGenerate a Seed with: session_id=\"interview_x\""

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => completion}]}
          })
        ]
      end)

    pcf = fn _payload -> {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)} end

    assert :ok ==
             LoopBindings.run_interview_session(agent,
               parent_call_id: "parent-done",
               initial_payload: %{
                 "params" => %{"name" => "ouroboros_interview", "arguments" => %{}}
               },
               parent_call_fun: pcf,
               model: scripted_model([]),
               project_dir: File.cwd!()
             )

    assert LoopBindings.pane_snapshot(agent).interview.complete == :seed_ready
  end

  defp parent_result(response) do
    %Ourocode.MCP.ParentCallResult{
      parent_call_id: "p",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      external_ids: %{},
      response: response
    }
  end

  defp scripted_model(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    %Ourocode.Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn _prompt, _opts, _on_chunk ->
        Agent.get_and_update(agent, fn
          [next | rest] -> {{:ok, next}, rest}
          [] -> {{:ok, "ASK_USER (script exhausted)"}, []}
        end)
      end
    }
  end

  defp hanging_model do
    %Ourocode.Model{
      id: :slow_fake,
      label: "slow fake",
      kind: :cli,
      status: :ready,
      run: fn _prompt, _opts, _on_chunk ->
        Process.sleep(:infinity)
      end
    }
  end

  defp wait_for(fun, attempts \\ 50) do
    cond do
      attempts <= 0 -> flunk("condition not met in time")
      fun.() -> :ok
      true -> Process.sleep(20) && wait_for(fun, attempts - 1)
    end
  end

  defp drain_all(poll, acc) do
    case poll.(%{}) do
      {:ok, event} -> drain_all(poll, [event | acc])
      :none -> Enum.reverse(acc)
    end
  end

  defp start_isolated_agent do
    {:ok, agent} = LoopBindings.start_link()
    agent
  end

  test "attach skips results without a runtime pipeline" do
    assert :skip == LoopBindings.attach(%{status: :healthy})
    assert :skip == LoopBindings.attach(%{status: :healthy, runtime: %{services: %{}}})
  end
end
