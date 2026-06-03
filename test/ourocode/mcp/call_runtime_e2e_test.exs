defmodule Ourocode.MCP.CallRuntimeE2ETest do
  use ExUnit.Case, async: false

  alias Ourocode.Dashboard.PaneOrchestrator
  alias Ourocode.Journal
  alias Ourocode.Journal.ReplayLoader
  alias Ourocode.Json
  alias Ourocode.MCP.CallRuntime
  alias Ourocode.MCP.ParentCallResult
  alias Ourocode.Runtime.LoopBindingEventFlow
  alias Ourocode.Runtime.LoopBindingState

  test "tool call streams parent pane, parallel child panes, wonder prompt, and replayable journal" do
    journal_path = journal_path("mcp-call-runtime-e2e")

    stream_events = [
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"childID" => "child-alpha", "seq" => 1, "token" => "alpha-start"}
      },
      %{
        "jsonrpc" => "2.0",
        "method" => "session/request_permission",
        "params" => %{
          "requestId" => "perm-beta",
          "childID" => "child-beta",
          "description" => "Allow child beta to inspect the journal?"
        }
      },
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"childID" => "child-beta", "seq" => 1, "token" => "beta-start"}
      },
      %{
        "jsonrpc" => "2.0",
        "id" => "request-ralph-1",
        "result" => %{
          "childID" => "child-alpha",
          "seq" => 2,
          "token" => "alpha-done",
          "status" => "completed"
        }
      }
    ]

    {:ok, server} = start_fake_http_mcp_sse_server(stream_events)
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent)
      File.rm(journal_path)
    end)

    assert {:ok, %ParentCallResult{} = result} =
             CallRuntime.execute_tool_call(
               [
                 url: "http://127.0.0.1:#{server.port}/mcp",
                 parent_call_id: "parent-ralph-1",
                 runtime_source: "ouroboros",
                 subscriber: self(),
                 journal_path: journal_path,
                 timeout: 2_000
               ],
               "ouroboros_ralph",
               %{"lineage_id" => "lin-1"},
               request_id: "request-ralph-1"
             )

    assert result.parent_call_id == "parent-ralph-1"
    assert result.response["result"]["status"] == "completed"

    events = receive_ourocode_events(5)
    Enum.each(events, &LoopBindingEventFlow.enqueue(agent, &1))

    state = Agent.get(agent, & &1)

    assert [%{parent_call_id: "parent-ralph-1", status: :completed}] = state.parent.completed
    assert [%{child_id: "child-beta", status: :working}] = state.child.working
    assert [%{child_id: "child-alpha", status: :completed}] = state.child.completed

    assert %{
             request_id: "perm-beta",
             parent_call_id: "parent-ralph-1",
             child_id: "child-beta",
             tool: :wonder_tool
           } = state.wonder

    assert Map.keys(state.mcp_topology.edges) |> Enum.sort() == [
             "mcp-parent:parent-ralph-1->child-session:child-alpha",
             "mcp-parent:parent-ralph-1->child-session:child-beta"
           ]

    assert {:ok, %{events: replayed_events, report: %{status: :ok}}} =
             ReplayLoader.load(journal_path)

    assert Enum.map(replayed_events, & &1.event_seq) == [1, 2, 3, 4, 5]

    replayed = PaneOrchestrator.from_events(replayed_events)
    assert [%{parent_call_id: "parent-ralph-1", status: :completed}] = replayed.parents.completed
    assert [%{child_id: "child-beta"}] = replayed.children.working
    assert [%{child_id: "child-alpha", status: :completed}] = replayed.children.completed

    assert {:ok, relationship_index} = Journal.load_relationship_recovery_index(journal_path)

    assert {:ok, parent_mapping} =
             Journal.RelationshipRecoveryIndex.parent(relationship_index, "parent-ralph-1")

    assert parent_mapping.child_ids == ["child-alpha", "child-beta"]

    assert_receive {:fake_server_request, raw_request}, 500
    assert raw_request =~ "\"method\":\"tools/call\""
    assert raw_request =~ "\"name\":\"ouroboros_ralph\""
    assert raw_request =~ "\"lineage_id\":\"lin-1\""
  end

  defp receive_ourocode_events(count), do: receive_ourocode_events(count, [])

  defp receive_ourocode_events(0, acc), do: Enum.reverse(acc)

  defp receive_ourocode_events(count, acc) do
    receive do
      {:ourocode_event, event} -> receive_ourocode_events(count - 1, [event | acc])
    after
      1_000 -> flunk("timed out waiting for #{count} more ourocode events")
    end
  end

  defp start_fake_http_mcp_sse_server(events) when is_list(events) do
    parent = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = recv_http_request(socket, "")
        send(parent, {:fake_server_request, request})

        response_body =
          events
          |> Enum.map(&sse_frame/1)
          |> IO.iodata_to_binary()

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: text/event-stream\r\n",
            "cache-control: no-cache\r\n",
            "content-length: #{byte_size(response_body)}\r\n",
            "connection: close\r\n",
            "\r\n",
            response_body
          ])

        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, port: port}}
  end

  defp sse_frame(payload) do
    ["event: message\n", "data: ", Json.encode!(payload), "\n\n"]
  end

  defp recv_http_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} ->
        next = acc <> chunk

        if complete_http_request?(next) do
          {:ok, next}
        else
          recv_http_request(socket, next)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_http_request?(request) do
    with [headers, body] <- String.split(request, "\r\n\r\n", parts: 2),
         [length] <- Regex.run(~r/content-length:\s*(\d+)/i, headers, capture: :all_but_first),
         {content_length, ""} <- Integer.parse(length) do
      byte_size(body) >= content_length
    else
      _ -> false
    end
  end

  defp journal_path(name) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")

    File.rm(path)
    path
  end
end
