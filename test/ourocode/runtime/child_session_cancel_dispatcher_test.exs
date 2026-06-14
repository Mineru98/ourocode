defmodule Ourocode.Runtime.ChildSessionCancelDispatcherTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.{ChildSessionActionDispatch, ChildSessionCancelDispatcher, FocusState}

  @mcp_url "http://127.0.0.1:4000/mcp"

  defp recording_cancel_caller(test_pid, result \\ {:ok, %{"status" => "cancelled"}}) do
    fn opts, payload ->
      send(test_pid, {:cancel_called, opts, payload})
      result
    end
  end

  defp focused_child_fixture(external_ids, runtime_source \\ "ouroboros") do
    pane_model = %{
      panes: %{
        "child-session:job-42" => %{
          id: "child-session:job-42",
          kind: :child_session,
          child_id: "job-42",
          parent_call_id: "parent-job-42",
          runtime_source: runtime_source,
          transport: :streamable_http,
          external_ids: external_ids
        }
      },
      open: ["child-session:job-42"]
    }

    {:ok, focus_state, _event} =
      FocusState.focus_pane(FocusState.new(), "child-session:job-42", pane_model)

    {focus_state, pane_model}
  end

  test "job-backed pane cancels through ouroboros_cancel_job" do
    {focus_state, pane_model} = focused_child_fixture(%{"job_id" => "job-42"})

    dispatcher =
      ChildSessionCancelDispatcher.build(
        mcp_url: @mcp_url,
        cancel_caller: recording_cancel_caller(self())
      )

    assert {:ok, %{delivery_result: delivery_result}} =
             ChildSessionActionDispatch.dispatch_cancel(
               %{command: "/cancel", args: [], event_seq: 7},
               focus_state: focus_state,
               pane_model: pane_model,
               child_session_cancel_dispatcher: dispatcher
             )

    assert delivery_result.tool == "ouroboros_cancel_job"
    assert delivery_result.arguments == %{"job_id" => "job-42"}

    assert_receive {:cancel_called, opts, payload}
    assert opts[:url] == @mcp_url
    assert opts[:parent_call_id] == "parent-job-42"
    assert opts[:mcp_session] == true
    assert payload["method"] == "tools/call"
    assert payload["params"]["name"] == "ouroboros_cancel_job"
    assert payload["params"]["arguments"] == %{"job_id" => "job-42"}
  end

  test "execution-backed pane cancels through ouroboros_cancel_execution with the reason" do
    {focus_state, pane_model} = focused_child_fixture(%{"execution_id" => "exec-9"})

    dispatcher =
      ChildSessionCancelDispatcher.build(
        mcp_url: @mcp_url,
        cancel_caller: recording_cancel_caller(self())
      )

    assert {:ok, %{delivery_result: delivery_result}} =
             ChildSessionActionDispatch.dispatch_cancel(
               %{command: "/cancel", args: ["wrong", "branch"], event_seq: 8},
               focus_state: focus_state,
               pane_model: pane_model,
               child_session_cancel_dispatcher: dispatcher
             )

    assert delivery_result.tool == "ouroboros_cancel_execution"

    assert_receive {:cancel_called, _opts, payload}
    assert payload["params"]["name"] == "ouroboros_cancel_execution"

    assert payload["params"]["arguments"] == %{
             "execution_id" => "exec-9",
             "reason" => "wrong branch"
           }
  end

  test "job_id wins when both job and execution handles are present" do
    {focus_state, pane_model} =
      focused_child_fixture(%{"job_id" => "job-42", "execution_id" => "exec-9"})

    dispatcher =
      ChildSessionCancelDispatcher.build(
        mcp_url: @mcp_url,
        cancel_caller: recording_cancel_caller(self())
      )

    assert {:ok, _result} =
             ChildSessionActionDispatch.dispatch_interrupt(
               %{command: "/interrupt", args: [], event_seq: 9},
               focus_state: focus_state,
               pane_model: pane_model,
               child_session_interrupt_dispatcher: dispatcher
             )

    assert_receive {:cancel_called, _opts, payload}
    assert payload["params"]["name"] == "ouroboros_cancel_job"
  end

  test "pane without job or execution handles is not cancellable" do
    {focus_state, pane_model} = focused_child_fixture(%{"session_id" => "sess-1"})

    dispatcher =
      ChildSessionCancelDispatcher.build(
        mcp_url: @mcp_url,
        cancel_caller: recording_cancel_caller(self())
      )

    assert {:error, {:child_pane_not_cancellable, "child-session:job-42"}} =
             ChildSessionActionDispatch.dispatch_cancel(
               %{command: "/cancel", args: []},
               focus_state: focus_state,
               pane_model: pane_model,
               child_session_cancel_dispatcher: dispatcher
             )

    refute_receive {:cancel_called, _opts, _payload}, 10
  end

  test "non-ouroboros runtime pane is not cancelled even with a job handle" do
    {focus_state, pane_model} = focused_child_fixture(%{"job_id" => "job-42"}, "codex")

    dispatcher =
      ChildSessionCancelDispatcher.build(
        mcp_url: @mcp_url,
        cancel_caller: recording_cancel_caller(self())
      )

    assert {:error, {:child_pane_not_cancellable, "child-session:job-42"}} =
             ChildSessionActionDispatch.dispatch_cancel(
               %{command: "/cancel", args: []},
               focus_state: focus_state,
               pane_model: pane_model,
               child_session_cancel_dispatcher: dispatcher
             )

    refute_receive {:cancel_called, _opts, _payload}, 10
  end

  test "transport errors surface as the delivery error" do
    {focus_state, pane_model} = focused_child_fixture(%{"job_id" => "job-42"})

    dispatcher =
      ChildSessionCancelDispatcher.build(
        mcp_url: @mcp_url,
        cancel_caller: recording_cancel_caller(self(), {:error, :econnrefused})
      )

    assert {:error, :econnrefused} =
             ChildSessionActionDispatch.dispatch_cancel(
               %{command: "/cancel", args: []},
               focus_state: focus_state,
               pane_model: pane_model,
               child_session_cancel_dispatcher: dispatcher
             )
  end

  test "missing dispatcher options keep the existing not-configured errors" do
    {focus_state, pane_model} = focused_child_fixture(%{"job_id" => "job-42"})

    assert {:error, :child_session_cancel_dispatcher_not_configured} =
             ChildSessionActionDispatch.dispatch_cancel(
               %{command: "/cancel", args: []},
               focus_state: focus_state,
               pane_model: pane_model
             )

    assert {:error, :child_session_interrupt_dispatcher_not_configured} =
             ChildSessionActionDispatch.dispatch_interrupt(
               %{command: "/interrupt", args: []},
               focus_state: focus_state,
               pane_model: pane_model
             )
  end
end
