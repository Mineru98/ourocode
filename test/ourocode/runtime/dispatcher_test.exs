defmodule Ourocode.Runtime.DispatcherTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Dispatcher
  alias Ourocode.Runtime.FocusState
  alias Ourocode.Json
  alias Ourocode.TaskRequest

  defmodule RuntimeAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:adapter_called, __MODULE__, task_request, context})
      {:ok, {:runtime, task_request.id}}
    end
  end

  defmodule CodexAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:adapter_called, __MODULE__, task_request, context})
      {:ok, {:codex, task_request.id}}
    end
  end

  defmodule OuroborosAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:adapter_called, __MODULE__, task_request, context})
      {:ok, {:ouroboros, task_request.id}}
    end
  end

  defmodule OuroborosInterviewAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:adapter_called, __MODULE__, task_request, context})
      {:ok, {:ouroboros_interview, task_request.id}}
    end
  end

  defmodule OuroborosEvolveAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:adapter_called, __MODULE__, task_request, context})
      {:ok, {:ouroboros_evolve, task_request.id}}
    end
  end

  defmodule OuroborosRalphAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:adapter_called, __MODULE__, task_request, context})
      {:ok, {:ouroboros_ralph, task_request.id}}
    end
  end

  defmodule MCPAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:adapter_called, __MODULE__, task_request, context})
      {:ok, {:mcp, task_request.id}}
    end
  end

  defmodule StdioMCPAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:adapter_called, __MODULE__, task_request, context})
      {:ok, {:mcp_stdio, task_request.id}}
    end
  end

  defmodule StreamableHTTPMCPAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:adapter_called, __MODULE__, task_request, context})
      {:ok, {:mcp_streamable_http, task_request.id}}
    end
  end

  defmodule SSEMCPAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:adapter_called, __MODULE__, task_request, context})
      {:ok, {:mcp_sse, task_request.id}}
    end
  end

  defmodule FailingAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(_task_request, _context), do: {:error, :adapter_failed}
  end

  defmodule ExternalCodexCommandAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(_task_request, context) do
      context.external_command_runner.("codex", ["exec", "inspect session recovery"], [])
    end
  end

  defmodule ShellWrappedClaudeCommandAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(_task_request, context) do
      context.external_command_runner.("sh", ["-c", "claude-code --print inspect"], [])
    end
  end

  defmodule AllowedHelperCommandAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(_task_request, context) do
      context.external_command_runner.("/usr/local/bin/ourocode-helper", ["scan"], [])
    end
  end

  defmodule InvalidAdapter do
  end

  test "dispatches default natural-language runtime route to runtime adapter" do
    task_request = parse!("Investigate child pane stream recovery", id: "runtime-task")

    assert {:ok, {:runtime, "runtime-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: %{runtime: RuntimeAdapter},
               context: %{test_pid: self(), journal_scope: "dispatch-test"}
             )

    assert_receive {:adapter_called, RuntimeAdapter, ^task_request, context}
    assert context.execution_route == :runtime
    assert context.runtime_source == :auto
    assert context.transport == :auto
    assert context.journal_scope == "dispatch-test"
    assert context.routing_decision == task_request.routing_decision
  end

  test "source-specific runtime adapter wins over generic runtime adapter" do
    task_request = parse!("codex inspect session recovery over stdio", id: "codex-task")

    assert {:ok, {:codex, "codex-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: %{runtime: RuntimeAdapter, codex: CodexAdapter},
               context: %{test_pid: self()}
             )

    assert_receive {:adapter_called, CodexAdapter, ^task_request, context}
    assert context.execution_route == :runtime
    assert context.runtime_source == :codex
    assert context.transport == :stdio
  end

  test "dispatches ouroboros workflow routes to ouroboros adapter" do
    task_request = parse!("ooo interview clarify cleanup policy", id: "ouroboros-task")

    assert {:ok, {:ouroboros, "ouroboros-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: %{ouroboros_workflow: OuroborosAdapter},
               context: %{test_pid: self()}
             )

    assert_receive {:adapter_called, OuroborosAdapter, ^task_request, context}
    assert context.execution_route == :ouroboros_workflow
    assert context.runtime_source == :ouroboros
  end

  test "dispatches explicit Ouroboros workflow actions to tuple-keyed adapters" do
    task_request = parse!("ooo interview clarify cleanup policy", id: "interview-task")

    assert {:ok, {:ouroboros_interview, "interview-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: %{
                 {:ouroboros_workflow, :interview} => OuroborosInterviewAdapter,
                 ouroboros_workflow: OuroborosAdapter
               },
               context: %{test_pid: self()}
             )

    assert_receive {:adapter_called, OuroborosInterviewAdapter, ^task_request, context}
    assert context.execution_route == :ouroboros_workflow
    assert context.runtime_source == :ouroboros
    assert context.adapter_route == :interview
    assert context.routing_decision.adapter_route == :interview
  end

  test "dispatches natural-language Ouroboros workflow actions to source-action adapters" do
    task_request =
      parse!("Run Ouroboros workflow evolve for the plugin renderer", id: "evolve-task")

    assert {:ok, {:ouroboros_evolve, "evolve-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: %{
                 {:ouroboros, :evolve} => OuroborosEvolveAdapter,
                 ouroboros_workflow: OuroborosAdapter
               },
               context: %{test_pid: self()}
             )

    assert_receive {:adapter_called, OuroborosEvolveAdapter, ^task_request, context}
    assert context.routing_decision.adapter_route == :evolve
    assert context.routing_decision.reason == :ouroboros_workflow_terms
  end

  test "dispatches Ouroboros workflow actions to atom shorthand adapters" do
    task_request = parse!("ouroboros:ralph repair failing stream test", id: "ralph-task")

    assert {:ok, {:ouroboros_ralph, "ralph-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: %{ouroboros_ralph: OuroborosRalphAdapter},
               context: %{test_pid: self()}
             )

    assert_receive {:adapter_called, OuroborosRalphAdapter, ^task_request, context}
    assert context.routing_decision.adapter_route == :ralph
  end

  test "dispatches MCP flow routes to MCP adapter" do
    task_request = parse!("MCP tools/call over streamable HTTP", id: "mcp-task")

    assert {:ok, {:mcp, "mcp-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: %{mcp_flow: MCPAdapter},
               context: %{test_pid: self()}
             )

    assert_receive {:adapter_called, MCPAdapter, ^task_request, context}
    assert context.execution_route == :mcp_flow
    assert context.runtime_source == :mcp
    assert context.transport == :streamable_http
  end

  test "dispatches MCP stdio routes to transport-specific adapters" do
    task_request = parse!("mcp:stdio tools/call ooo.run", id: "mcp-stdio-task")

    assert {:ok, {:mcp_stdio, "mcp-stdio-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: %{
                 {:mcp_flow, :stdio} => StdioMCPAdapter,
                 mcp_flow: MCPAdapter
               },
               context: %{test_pid: self()}
             )

    assert_receive {:adapter_called, StdioMCPAdapter, ^task_request, context}
    assert context.execution_route == :mcp_flow
    assert context.runtime_source == :mcp
    assert context.transport == :stdio
    assert context.routing_decision == task_request.routing_decision
  end

  test "dispatches MCP streamable HTTP routes to source-transport adapters" do
    task_request = parse!("MCP tools/call over streamable HTTP", id: "mcp-http-task")

    assert {:ok, {:mcp_streamable_http, "mcp-http-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: %{
                 {:mcp, :streamable_http} => StreamableHTTPMCPAdapter,
                 mcp_flow: MCPAdapter
               },
               context: %{test_pid: self()}
             )

    assert_receive {:adapter_called, StreamableHTTPMCPAdapter, ^task_request, context}
    assert context.execution_route == :mcp_flow
    assert context.runtime_source == :mcp
    assert context.transport == :streamable_http
  end

  test "dispatches MCP SSE routes to atom shorthand adapters" do
    task_request = parse!("mcp tools/call over sse", id: "mcp-sse-task")

    assert {:ok, {:mcp_sse, "mcp-sse-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: %{mcp_sse: SSEMCPAdapter, mcp_flow: MCPAdapter},
               context: %{test_pid: self()}
             )

    assert_receive {:adapter_called, SSEMCPAdapter, ^task_request, context}
    assert context.execution_route == :mcp_flow
    assert context.runtime_source == :mcp
    assert context.transport == :sse
  end

  test "falls back to generic MCP adapter when no transport-specific adapter is registered" do
    task_request = parse!("mcp:stdio tools/call ooo.run", id: "mcp-fallback-task")

    assert {:ok, {:mcp, "mcp-fallback-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: %{mcp_flow: MCPAdapter},
               context: %{test_pid: self()}
             )

    assert_receive {:adapter_called, MCPAdapter, ^task_request, context}
    assert context.transport == :stdio
  end

  test "returns adapter errors without swallowing them" do
    task_request = parse!("Investigate child pane stream recovery", id: "failing-task")

    assert Dispatcher.dispatch(task_request, adapters: %{runtime: FailingAdapter}) ==
             {:error, :adapter_failed}
  end

  test "dispatcher command runner rejects external codex invocation before any runner is called" do
    task_request = parse!("codex inspect session recovery", id: "codex-command-denied-task")

    command_runner = fn command, args, opts ->
      send(self(), {:external_command_invoked, command, args, opts})
      {:ok, "should not run"}
    end

    assert Dispatcher.dispatch(task_request,
             adapters: %{codex: ExternalCodexCommandAdapter},
             external_command_runner: command_runner
           ) == {:error, {:forbidden_external_command, "codex"}}

    refute_received {:external_command_invoked, _command, _args, _opts}
  end

  test "dispatcher command runner rejects shell-wrapped claude-code invocation" do
    task_request =
      parse!("claude-code inspect session recovery", id: "claude-command-denied-task")

    command_runner = fn command, args, opts ->
      send(self(), {:external_command_invoked, command, args, opts})
      {:ok, "should not run"}
    end

    assert Dispatcher.dispatch(task_request,
             adapters: %{claude_code: ShellWrappedClaudeCommandAdapter},
             external_command_runner: command_runner
           ) == {:error, {:forbidden_external_command, :shell_wrapped_agent_command}}

    refute_received {:external_command_invoked, _command, _args, _opts}
  end

  test "dispatcher command runner permits non-agent helper commands through explicit runner" do
    task_request = parse!("Investigate helper scan dispatch", id: "helper-command-task")

    command_runner = fn command, args, opts ->
      send(self(), {:external_command_invoked, command, args, opts})
      {:ok, %{command: command, args: args}}
    end

    assert {:ok, %{command: "/usr/local/bin/ourocode-helper", args: ["scan"]}} =
             Dispatcher.dispatch(task_request,
               adapters: %{runtime: AllowedHelperCommandAdapter},
               external_command_runner: command_runner
             )

    assert_received {:external_command_invoked, "/usr/local/bin/ourocode-helper", ["scan"], []}
  end

  test "steering dispatcher resolves focused child pane and delivers serialized message" do
    input_event = %{
      type: :prompt_input_submitted,
      event_type: :prompt_input_submitted,
      source: :terminal_prompt,
      input_kind: :natural_language,
      event_seq: 42,
      task_request_id: "task-steering-1",
      task_input: "summarize this child pane",
      focused_pane: "child-session:bravo",
      steering_target: :child,
      steering_target_pane_id: "child-session:bravo",
      steering_target_session_id: "bravo",
      steering_target_kind: :child_session,
      steering_text: "summarize this child pane",
      steering_message: %{
        type: :pane_directed_steering_message,
        target_pane_id: "child-session:bravo",
        target_session_id: "bravo",
        target_kind: :child_session,
        content: "summarize this child pane"
      }
    }

    pane_model = %{
      panes: %{
        "child-session:bravo" => %{
          id: "child-session:bravo",
          kind: :child_session,
          child_id: "bravo",
          transport: :stdio
        },
        parent: %{id: :parent, kind: :parent_session}
      },
      open: [:parent, "child-session:bravo"]
    }

    dispatcher = fn pane, serialized_message, context ->
      send(self(), {:child_pane_dispatched, pane, serialized_message, context})
      {:ok, :delivered}
    end

    assert {:ok,
            %{
              pane: %{id: "child-session:bravo", child_id: "bravo"},
              serialized_message: serialized_message,
              decoded_message: decoded_message,
              delivery_result: :delivered
            }} =
             Dispatcher.dispatch_steering_message(input_event,
               pane_model: pane_model,
               child_pane_dispatcher: dispatcher,
               context: %{journal_scope: "steering-test"}
             )

    assert_receive {:child_pane_dispatched, %{id: "child-session:bravo"}, ^serialized_message,
                    %{journal_scope: "steering-test", decoded_message: ^decoded_message}}

    assert {:ok, wire_message} = Json.decode(serialized_message)
    assert wire_message["type"] == "pane_directed_steering_message"
    assert wire_message["target_pane_id"] == "child-session:bravo"
    assert wire_message["target_session_id"] == "bravo"
    assert wire_message["target_kind"] == "child_session"
    assert wire_message["content"] == "summarize this child pane"
    assert wire_message["source_event_seq"] == 42
    assert wire_message["pane_id"] == "child-session:bravo"
    assert wire_message["child_id"] == "bravo"
  end

  test "steering dispatcher does not deliver serialized message to sibling child panes or parent pane" do
    input_event = %{
      type: :prompt_input_submitted,
      event_type: :prompt_input_submitted,
      source: :terminal_prompt,
      input_kind: :natural_language,
      event_seq: 43,
      task_request_id: "task-steering-isolated",
      task_input: "continue only in bravo",
      focused_pane: "child-session:bravo",
      steering_target: :child,
      steering_target_pane_id: "child-session:bravo",
      steering_target_session_id: "alpha",
      steering_target_kind: :parent_session,
      steering_text: "continue only in bravo",
      steering_message: %{
        type: :pane_directed_steering_message,
        target_pane_id: "child-session:bravo",
        target_session_id: "parent",
        target_kind: :parent_session,
        content: "continue only in bravo"
      }
    }

    pane_model = %{
      panes: %{
        :parent => %{id: :parent, kind: :parent_session, session_id: "parent"},
        "child-session:alpha" => %{
          id: "child-session:alpha",
          kind: :child_session,
          child_id: "alpha",
          transport: :sse
        },
        "child-session:bravo" => %{
          id: "child-session:bravo",
          kind: :child_session,
          child_id: "bravo",
          transport: :stdio
        }
      },
      open: [:parent, "child-session:alpha", "child-session:bravo"]
    }

    dispatcher = fn
      %{id: "child-session:bravo"} = pane, serialized_message, context ->
        send(self(), {:delivered_to_target_child, pane, serialized_message, context})
        {:ok, :target_child_only}

      %{id: "child-session:alpha"} = pane, serialized_message, context ->
        send(self(), {:delivered_to_sibling_child, pane, serialized_message, context})
        {:ok, :sibling_child}

      %{id: :parent} = pane, serialized_message, context ->
        send(self(), {:delivered_to_parent, pane, serialized_message, context})
        {:ok, :parent}
    end

    assert {:ok,
            %{
              pane: %{id: "child-session:bravo", child_id: "bravo"},
              serialized_message: serialized_message,
              decoded_message: decoded_message,
              delivery_result: :target_child_only
            }} =
             Dispatcher.dispatch_steering_message(input_event,
               pane_model: pane_model,
               child_pane_dispatcher: dispatcher
             )

    assert_receive {:delivered_to_target_child, %{id: "child-session:bravo"}, ^serialized_message,
                    %{decoded_message: ^decoded_message}}

    refute_received {:delivered_to_sibling_child, _pane, _serialized_message, _context}
    refute_received {:delivered_to_parent, _pane, _serialized_message, _context}

    assert {:ok, wire_message} = Json.decode(serialized_message)
    assert wire_message["target_pane_id"] == "child-session:bravo"
    assert wire_message["target_session_id"] == "bravo"
    assert wire_message["target_kind"] == "child_session"
    assert wire_message["pane_id"] == "child-session:bravo"
    assert wire_message["child_id"] == "bravo"

    refute wire_message["target_pane_id"] == "child-session:alpha"
    refute wire_message["target_session_id"] == "alpha"
    refute wire_message["target_kind"] == "parent_session"
  end

  test "steering dispatcher routes by current focus when steering payload is stale" do
    input_event = %{
      type: :prompt_input_submitted,
      event_type: :prompt_input_submitted,
      source: :terminal_prompt,
      input_kind: :natural_language,
      event_seq: 44,
      task_request_id: "task-steering-current-focus",
      task_input: "apply this to the focused child",
      focused_pane: "child-session:alpha",
      focus_state: %{
        focused_pane: "child-session:alpha",
        steering_target: :child,
        steering_target_pane_id: "child-session:alpha",
        steering_target_session_id: "alpha",
        steering_target_kind: :child_session
      },
      steering_target: :child,
      steering_target_pane_id: "child-session:alpha",
      steering_target_session_id: "alpha",
      steering_target_kind: :child_session,
      steering_text: "apply this to the focused child",
      steering_message: %{
        type: :pane_directed_steering_message,
        target_pane_id: "child-session:alpha",
        target_session_id: "alpha",
        target_kind: :child_session,
        content: "apply this to the focused child"
      }
    }

    pane_model = %{
      panes: %{
        "child-session:alpha" => %{
          id: "child-session:alpha",
          kind: :child_session,
          child_id: "alpha",
          transport: :sse
        },
        "child-session:bravo" => %{
          id: "child-session:bravo",
          kind: :child_session,
          child_id: "bravo",
          transport: :stdio
        }
      },
      open: ["child-session:alpha", "child-session:bravo"]
    }

    current_focus_state = %{
      focused_pane: "child-session:bravo",
      steering_target: :child,
      steering_target_pane_id: "child-session:bravo",
      steering_target_session_id: "bravo",
      steering_target_kind: :child_session
    }

    dispatcher = fn
      %{id: "child-session:bravo"} = pane, serialized_message, context ->
        send(self(), {:delivered_to_current_focus, pane, serialized_message, context})
        {:ok, :current_focus_child}

      %{id: "child-session:alpha"} = pane, serialized_message, context ->
        send(self(), {:delivered_to_stale_target, pane, serialized_message, context})
        {:ok, :stale_target}
    end

    assert {:ok,
            %{
              pane: %{id: "child-session:bravo", child_id: "bravo"},
              serialized_message: serialized_message,
              decoded_message: decoded_message,
              delivery_result: :current_focus_child
            }} =
             Dispatcher.dispatch_steering_message(input_event,
               pane_model: pane_model,
               child_pane_dispatcher: dispatcher,
               context: %{focus_state: current_focus_state}
             )

    assert_receive {:delivered_to_current_focus, %{id: "child-session:bravo"},
                    ^serialized_message, %{decoded_message: ^decoded_message}}

    refute_received {:delivered_to_stale_target, _pane, _serialized_message, _context}

    assert {:ok, wire_message} = Json.decode(serialized_message)
    assert wire_message["target_pane_id"] == "child-session:bravo"
    assert wire_message["target_session_id"] == "bravo"
    assert wire_message["pane_id"] == "child-session:bravo"
    assert wire_message["child_id"] == "bravo"
    assert wire_message["content"] == "apply this to the focused child"
  end

  test "steering dispatcher rejects child steering when focused pane is missing" do
    input_event = %{
      steering_target: :child,
      steering_message: %{
        type: :pane_directed_steering_message,
        target_pane_id: "child-session:missing",
        content: "hello"
      }
    }

    assert Dispatcher.dispatch_steering_message(input_event,
             pane_model: %{panes: %{}, open: []},
             child_pane_dispatcher: fn _pane, _serialized -> :ok end
           ) == {:error, {:focused_child_pane_not_found, "child-session:missing"}}
  end

  test "interrupt action dispatches only to the resolved focused child session" do
    pane_model = %{
      panes: %{
        :parent => %{id: :parent, kind: :parent_session, session_id: "parent"},
        "child-session:alpha" => %{
          id: "child-session:alpha",
          kind: :child_session,
          child_id: "alpha",
          transport: :sse
        },
        "child-session:bravo" => %{
          id: "child-session:bravo",
          kind: :child_session,
          child_id: "bravo",
          transport: :stdio
        }
      },
      open: [:parent, "child-session:alpha", "child-session:bravo"]
    }

    assert {:ok, focus_state, _event} =
             FocusState.focus_pane(FocusState.new(), "child-session:bravo", pane_model)

    command_event = %{
      type: :slash_command_submitted,
      event_type: :slash_command_submitted,
      source: :terminal_prompt,
      input_kind: :slash_command,
      command: "/interrupt",
      args: ["stop", "current", "work"],
      event_seq: 77,
      focused_pane: "child-session:alpha",
      steering_target_pane_id: "child-session:alpha",
      run_spec: %{
        kind: :builtin_action,
        action: :interrupt_focused_child,
        target: :focused_child_session,
        child_session_id: "alpha",
        child_pane_id: "child-session:alpha"
      }
    }

    dispatcher = fn
      %{id: "child-session:bravo"} = pane, serialized_request, context ->
        send(self(), {:interrupt_delivered_to_focus, pane, serialized_request, context})
        {:ok, :focused_child_interrupted}

      %{id: "child-session:alpha"} = pane, serialized_request, context ->
        send(self(), {:interrupt_delivered_to_sibling, pane, serialized_request, context})
        {:ok, :sibling_child}

      %{id: :parent} = pane, serialized_request, context ->
        send(self(), {:interrupt_delivered_to_parent, pane, serialized_request, context})
        {:ok, :parent}
    end

    assert {:ok,
            %{
              focused_child: %{
                pane_id: "child-session:bravo",
                session_id: "bravo",
                child_id: "bravo",
                kind: :child_session
              },
              pane: %{id: "child-session:bravo", child_id: "bravo"},
              serialized_request: serialized_request,
              decoded_request: decoded_request,
              delivery_result: :focused_child_interrupted
            }} =
             Dispatcher.dispatch_interrupt_action(command_event,
               focus_state: focus_state,
               pane_model: pane_model,
               child_session_interrupt_dispatcher: dispatcher,
               context: %{journal_scope: "interrupt-test"}
             )

    assert_receive {:interrupt_delivered_to_focus, %{id: "child-session:bravo"},
                    ^serialized_request,
                    %{journal_scope: "interrupt-test", decoded_request: ^decoded_request}}

    refute_received {:interrupt_delivered_to_sibling, _pane, _serialized_request, _context}
    refute_received {:interrupt_delivered_to_parent, _pane, _serialized_request, _context}

    assert {:ok, wire_request} = Json.decode(serialized_request)
    assert wire_request["type"] == "child_session_interrupt_request"
    assert wire_request["action"] == "interrupt"
    assert wire_request["target_pane_id"] == "child-session:bravo"
    assert wire_request["target_session_id"] == "bravo"
    assert wire_request["target_kind"] == "child_session"
    assert wire_request["child_id"] == "bravo"
    assert wire_request["pane_id"] == "child-session:bravo"
    assert wire_request["source_command"] == "/interrupt"
    assert wire_request["source_args"] == ["stop", "current", "work"]
    assert wire_request["source_event_seq"] == 77
    assert wire_request["reason"] == "stop current work"

    refute wire_request["target_pane_id"] == "child-session:alpha"
    refute wire_request["target_session_id"] == "alpha"
  end

  test "cancel action dispatches only to the resolved focused child session" do
    pane_model = %{
      panes: %{
        :parent => %{id: :parent, kind: :parent_session, session_id: "parent"},
        "child-session:alpha" => %{
          id: "child-session:alpha",
          kind: :child_session,
          child_id: "alpha",
          transport: :sse
        },
        "child-session:bravo" => %{
          id: "child-session:bravo",
          kind: :child_session,
          child_id: "bravo",
          transport: :stdio
        }
      },
      open: [:parent, "child-session:alpha", "child-session:bravo"]
    }

    assert {:ok, focus_state, _event} =
             FocusState.focus_pane(FocusState.new(), "child-session:bravo", pane_model)

    command_event = %{
      type: :slash_command_submitted,
      event_type: :slash_command_submitted,
      source: :terminal_prompt,
      input_kind: :slash_command,
      command: "/cancel",
      args: ["user", "cancelled", "run"],
      event_seq: 88,
      focused_pane: "child-session:alpha",
      steering_target_pane_id: "child-session:alpha",
      run_spec: %{
        kind: :builtin_action,
        action: :cancel_focused_child,
        target: :focused_child_session,
        child_session_id: "alpha",
        child_pane_id: "child-session:alpha"
      }
    }

    dispatcher = fn
      %{id: "child-session:bravo"} = pane, serialized_request, context ->
        send(self(), {:cancel_delivered_to_focus, pane, serialized_request, context})
        {:ok, :focused_child_cancelled}

      %{id: "child-session:alpha"} = pane, serialized_request, context ->
        send(self(), {:cancel_delivered_to_sibling, pane, serialized_request, context})
        {:ok, :sibling_child}

      %{id: :parent} = pane, serialized_request, context ->
        send(self(), {:cancel_delivered_to_parent, pane, serialized_request, context})
        {:ok, :parent}
    end

    assert {:ok,
            %{
              focused_child: %{
                pane_id: "child-session:bravo",
                session_id: "bravo",
                child_id: "bravo",
                kind: :child_session
              },
              pane: %{id: "child-session:bravo", child_id: "bravo"},
              serialized_request: serialized_request,
              decoded_request: decoded_request,
              delivery_result: :focused_child_cancelled
            }} =
             Dispatcher.dispatch_cancel_action(command_event,
               focus_state: focus_state,
               pane_model: pane_model,
               child_session_cancel_dispatcher: dispatcher,
               context: %{journal_scope: "cancel-test"}
             )

    assert_receive {:cancel_delivered_to_focus, %{id: "child-session:bravo"}, ^serialized_request,
                    %{journal_scope: "cancel-test", decoded_request: ^decoded_request}}

    refute_received {:cancel_delivered_to_sibling, _pane, _serialized_request, _context}
    refute_received {:cancel_delivered_to_parent, _pane, _serialized_request, _context}

    assert {:ok, wire_request} = Json.decode(serialized_request)
    assert wire_request["type"] == "child_session_cancel_request"
    assert wire_request["action"] == "cancel"
    assert wire_request["target_pane_id"] == "child-session:bravo"
    assert wire_request["target_session_id"] == "bravo"
    assert wire_request["target_kind"] == "child_session"
    assert wire_request["child_id"] == "bravo"
    assert wire_request["pane_id"] == "child-session:bravo"
    assert wire_request["source_command"] == "/cancel"
    assert wire_request["source_args"] == ["user", "cancelled", "run"]
    assert wire_request["source_event_seq"] == 88
    assert wire_request["reason"] == "user cancelled run"

    refute wire_request["target_pane_id"] == "child-session:alpha"
    refute wire_request["target_session_id"] == "alpha"
  end

  test "returns a user-visible unsupported-task error when no internal flow exists" do
    task_request = parse!("codex inspect session recovery", id: "missing-adapter-task")

    assert {:error,
            %{
              code: :unsupported_task,
              message:
                "Unsupported task: no internal runtime flow is available for codex using auto.",
              task_input: "codex inspect session recovery",
              routing_decision: routing_decision,
              attempted_adapter_keys: [:codex, :runtime]
            }} = Dispatcher.dispatch(task_request, adapters: %{})

    assert routing_decision == task_request.routing_decision
  end

  test "rejects invalid adapters before execution" do
    task_request = parse!("codex inspect session recovery", id: "invalid-adapter-task")

    assert Dispatcher.dispatch(task_request, adapters: %{codex: InvalidAdapter}) ==
             {:error, {:invalid_adapter, InvalidAdapter}}
  end

  test "rejects malformed routing decisions" do
    task_request =
      %TaskRequest{
        id: "bad-route-task",
        source: :cli,
        task_input: "bad route",
        submitted_at_ms: 123,
        routing_decision: %{
          kind: :runtime,
          execution_route: :mcp_flow,
          runtime_source: :codex,
          transport: :stdio,
          requires_command_syntax?: false,
          advanced_shortcut?: false,
          reason: :test
        }
      }

    assert Dispatcher.dispatch(task_request, adapters: %{runtime: RuntimeAdapter}) ==
             {:error, {:route_mismatch, :runtime, :mcp_flow}}
  end

  defp parse!(input, options) do
    {:ok, task_request} = TaskRequest.parse(input, options)
    task_request
  end
end
