defmodule Ourocode.BaselineEndToEndTest do
  @moduledoc """
  Maps the seed `baseline_end_to_end_scenario` and `streaming_no_loss` criteria
  to one integration flow that drives the real public modules:

    1. natural-language `ooo interview` prompt parsing,
    2. parent MCP call dispatch through the interview workflow adapter,
    3. parent pane + ouroboros interview child pane creation,
    4. streamable HTTP interview tokens normalized, journaled, and rendered
       within the <=5s first-visible-event budget with no sequence loss,
    5. official ouroboros plugin visible as loaded in the plugin status area,
    6. focused child pane steering ("transport는 stdio, SSE, streamable HTTP
       모두 필요해.") routed and acknowledged back to that child session,
    7. journal replay reconstructing the same normalized event order.
  """

  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.{ChildSessionPanes, ParentMcpPane}
  alias Ourocode.Journal
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.StreamableHTTP
  alias Ourocode.Runtime.{Dispatcher, InterviewWorkflowInvocation}
  alias Ourocode.TaskRequest
  alias Ourocode.Terminal.PluginStatusArea

  @prompt "ooo interview로 ourocode의 MCP streamable UI 요구사항을 정리해줘"
  @steering_text "transport는 stdio, SSE, streamable HTTP 모두 필요해."
  @first_visible_event_budget_ms 5_000

  test "ooo interview baseline drives parent/child panes, <=5s no-loss streaming, and steering" do
    parent = self()

    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-baseline-e2e-#{System.unique_integer([:positive])}.jsonl"
      )

    File.rm(journal_path)
    on_exit(fn -> File.rm(journal_path) end)

    # 1. Natural-language prompt is preserved and routed to the interview adapter.
    assert {:ok, %TaskRequest{} = task_request} =
             TaskRequest.parse(@prompt, id: "interview-task", submitted_at_ms: 1_000)

    assert %{
             execution_route: :ouroboros_workflow,
             runtime_source: :ouroboros,
             adapter_route: :interview
           } = task_request.routing_decision

    # 2. Parent MCP call dispatch through the real dispatcher + interview adapter.
    invoker = fn payload, transport_options ->
      send(parent, {:mcp_invoked, payload, transport_options})
      {:ok, %{parent_call_id: "parent-interview-baseline-1"}}
    end

    assert {:ok,
            %{
              type: :interview_workflow_invocation,
              status: :invoked,
              transport: :streamable_http,
              mcp_tool: "ouroboros_interview",
              prompt_text: @prompt,
              result: %{parent_call_id: parent_call_id}
            }} =
             Dispatcher.dispatch(task_request,
               adapters: %{{:ouroboros_workflow, :interview} => InterviewWorkflowInvocation},
               context: %{
                 request_id: "req-interview-baseline",
                 streamable_http_url: "http://localhost:4000/mcp",
                 journal_path: journal_path,
                 mcp_invoker: invoker
               }
             )

    assert_receive {:mcp_invoked, payload, %{transport: :streamable_http}}
    assert payload["params"]["arguments"]["initial_context"] == @prompt

    # 3a. Parent main session pane appears as a first-class pane with a stable id.
    parent_started =
      LifecycleEvent.new(:parent_call_started, %{
        event_seq: 0,
        transport: :streamable_http,
        parent_call_id: parent_call_id,
        runtime_source: "ouroboros",
        external_ids: %{session_id: "session-interview-baseline-1"},
        occurred_at_ms: 9_500,
        request_id: "req-interview-baseline",
        method: "tools/call"
      })

    parent_state =
      ParentMcpPane.apply_event(
        %{working: [], completed: [], focused: nil, open: []},
        parent_started
      )

    parent_pane_id = ParentMcpPane.parent_pane_id(parent_call_id)
    rendered_parent = ParentMcpPane.render(parent_state)

    assert rendered_parent.focused == parent_pane_id
    assert [%{line: parent_line}] = rendered_parent.working
    assert parent_line =~ "parent=#{parent_call_id}"
    assert parent_line =~ "transport=streamable_http"

    # 4. Streamable HTTP interview tokens normalized through the shared pipeline.
    child_id = "child-interview-baseline-1"
    child_created_at_ms = 10_000

    body =
      [
        interview_frame(parent_call_id, child_id, 1, "어떤 MCP transport가 필요하신가요?"),
        interview_frame(parent_call_id, child_id, 2, "stdio/SSE/streamable HTTP 우선순위는?")
      ]
      |> IO.iodata_to_binary()

    assert {:ok, normalized_events} =
             StreamableHTTP.LifecycleNormalizer.normalize_body(
               200,
               [{"content-type", "text/event-stream"}],
               body,
               %{
                 event_seq: 1,
                 parent_call_id: parent_call_id,
                 runtime_source: "ouroboros",
                 external_ids: %{"session_id" => "session-interview-baseline-1"},
                 occurred_at_ms: child_created_at_ms + 1_200
               }
             )

    assert length(normalized_events) == 2
    assert Enum.map(normalized_events, & &1.event_seq) == [1, 2]
    assert Enum.all?(normalized_events, &(&1.transport == :streamable_http))

    Enum.each(normalized_events, fn event ->
      assert :ok = Journal.append(journal_path, StreamableHTTP.canonical_journal_event(event))
    end)

    # 4a. First-visible-event latency from child creation to first token <=5s.
    [first_event | _] = normalized_events
    first_visible_latency_ms = first_event.occurred_at_ms - child_created_at_ms
    assert first_visible_latency_ms >= 0
    assert first_visible_latency_ms <= @first_visible_event_budget_ms

    # 3b. The ouroboros interview child pane appears beside the parent pane.
    assert {:ok, child_state} =
             ChildSessionPanes.register_child_pane(ChildSessionPanes.new(), %{
               child_id: child_id,
               parent_call_id: parent_call_id,
               runtime_source: "ouroboros",
               transport: :streamable_http,
               external_ids: %{"session_id" => "session-interview-baseline-1"},
               created_at_ms: child_created_at_ms,
               updated_at_ms: first_event.occurred_at_ms,
               pane_state: %{
                 title: "Ouroboros Interview",
                 last_event_seq: 2,
                 stream_entries:
                   Enum.map(normalized_events, fn event ->
                     %{event_seq: event.event_seq, token: interview_token(event)}
                   end)
               }
             })

    child_pane_id = ChildSessionPanes.child_pane_id(child_id)
    assert child_pane_id == "child-session:#{child_id}"
    assert child_state.focused == child_pane_id
    assert child_pane_id != parent_pane_id

    rendered_child = ChildSessionPanes.render(child_state)

    assert [
             %{
               id: ^child_pane_id,
               pane_state: %{title: "Ouroboros Interview", stream_entries: child_stream_entries}
             }
           ] = rendered_child.working

    assert Enum.map(child_stream_entries, & &1.token) == [
             "어떤 MCP transport가 필요하신가요?",
             "stdio/SSE/streamable HTTP 우선순위는?"
           ]

    # 5. streaming_no_loss: contiguous monotonic sequence + replay reconstruction.
    assert {:ok, ordered_entries} = Journal.read_ordered(journal_path)
    assert length(ordered_entries) == 2
    assert Enum.map(ordered_entries, & &1.event_seq) == [1, 2]

    assert {:ok, replayed} = Journal.replay_normalized_events(journal_path)

    assert Enum.map(replayed, & &1.event_seq) ==
             Enum.map(normalized_events, & &1.event_seq)

    assert Enum.map(replayed, &interview_token/1) == [
             "어떤 MCP transport가 필요하신가요?",
             "stdio/SSE/streamable HTTP 우선순위는?"
           ]

    # 6. Official ouroboros plugin is visible as loaded in the plugin status area.
    plugin_text =
      PluginStatusArea.render_text(%{
        plugins: [
          %{
            plugin_id: "ouroboros-plugin",
            source_type: "official",
            version: "0.1.0",
            enabled?: true,
            load_state: :loaded,
            path: "plugins/ouroboros"
          }
        ]
      })

    assert plugin_text =~ "ouroboros-plugin"
    assert plugin_text =~ "source=official"
    assert plugin_text =~ "state=loaded"

    # 7. Focusing the child pane and steering routes to that child session only.
    pane_model = %{
      panes: %{
        child_pane_id => %{
          id: child_pane_id,
          kind: :child_session,
          child_id: child_id,
          transport: :streamable_http
        },
        parent: %{id: :parent, kind: :parent_session}
      },
      open: [:parent, child_pane_id]
    }

    input_event = %{
      type: :prompt_input_submitted,
      event_type: :prompt_input_submitted,
      source: :terminal_prompt,
      input_kind: :natural_language,
      event_seq: 99,
      task_request_id: "task-steering-baseline",
      task_input: @steering_text,
      focused_pane: child_pane_id,
      steering_target: :child,
      steering_target_pane_id: child_pane_id,
      steering_target_session_id: child_id,
      steering_target_kind: :child_session,
      steering_text: @steering_text,
      steering_message: %{
        type: :pane_directed_steering_message,
        target_pane_id: child_pane_id,
        target_session_id: child_id,
        target_kind: :child_session,
        content: @steering_text
      }
    }

    dispatcher = fn pane, serialized_message, context ->
      send(parent, {:child_pane_dispatched, pane, serialized_message, context})
      {:ok, :delivered}
    end

    assert {:ok,
            %{
              pane: %{id: ^child_pane_id, child_id: ^child_id},
              serialized_message: serialized_message,
              decoded_message: decoded_message,
              delivery_result: :delivered
            }} =
             Dispatcher.dispatch_steering_message(input_event,
               pane_model: pane_model,
               child_pane_dispatcher: dispatcher,
               context: %{journal_scope: "baseline-steering"}
             )

    assert_receive {:child_pane_dispatched, %{id: ^child_pane_id}, ^serialized_message,
                    %{journal_scope: "baseline-steering", decoded_message: ^decoded_message}}

    assert {:ok, wire_message} = Ourocode.Json.decode(serialized_message)
    assert wire_message["type"] == "pane_directed_steering_message"
    assert wire_message["target_session_id"] == child_id
    assert wire_message["content"] == @steering_text
    assert wire_message["source_event_seq"] == 99
  end

  defp interview_token(event) do
    notification = Map.get(event, :notification) || Map.get(event, "notification") || %{}
    params = Map.get(notification, "params") || Map.get(notification, :params) || %{}
    Map.get(params, "token") || Map.get(params, :token)
  end

  defp interview_frame(parent_call_id, child_id, seq, token) do
    json_rpc = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{
        "parentCallID" => parent_call_id,
        "childID" => child_id,
        "seq" => seq,
        "token" => token
      }
    }

    [
      "event: child-token\n",
      "id: interview-#{seq}\n",
      "data: ",
      Ourocode.Json.encode!(json_rpc),
      "\n\n"
    ]
  end
end
