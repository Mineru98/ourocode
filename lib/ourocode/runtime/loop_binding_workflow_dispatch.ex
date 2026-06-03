defmodule Ourocode.Runtime.LoopBindingWorkflowDispatch do
  @moduledoc """
  Dispatches routed Ouroboros workflow prompts from the prompt loop.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Catalog

  alias Ourocode.Runtime.{
    Dispatcher,
    InterviewProgress,
    InterviewWorkflowInvocation,
    LoopBindingEventFlow,
    McpDaemonBinding,
    OuroborosDirectInvocation,
    OuroborosWorkflowInvocation,
    WorkflowHarness,
    WorkflowRelay
  }

  @ouroboros_adapters %{
    {:ouroboros_workflow, :auto} => OuroborosWorkflowInvocation,
    {:ouroboros, :auto} => OuroborosWorkflowInvocation,
    :ouroboros_auto => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :interview} => InterviewWorkflowInvocation,
    {:ouroboros, :interview} => InterviewWorkflowInvocation,
    :ouroboros_interview => InterviewWorkflowInvocation,
    {:ouroboros_workflow, :seed} => OuroborosWorkflowInvocation,
    {:ouroboros, :seed} => OuroborosWorkflowInvocation,
    :ouroboros_seed => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :run} => OuroborosWorkflowInvocation,
    {:ouroboros, :run} => OuroborosWorkflowInvocation,
    :ouroboros_run => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :evolve} => OuroborosWorkflowInvocation,
    {:ouroboros, :evolve} => OuroborosWorkflowInvocation,
    :ouroboros_evolve => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :ralph} => OuroborosWorkflowInvocation,
    {:ouroboros, :ralph} => OuroborosWorkflowInvocation,
    :ouroboros_ralph => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :status} => OuroborosWorkflowInvocation,
    {:ouroboros, :status} => OuroborosWorkflowInvocation,
    :ouroboros_status => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :evaluate} => OuroborosWorkflowInvocation,
    {:ouroboros, :evaluate} => OuroborosWorkflowInvocation,
    :ouroboros_evaluate => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :qa} => OuroborosWorkflowInvocation,
    {:ouroboros, :qa} => OuroborosWorkflowInvocation,
    :ouroboros_qa => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :lateral} => OuroborosWorkflowInvocation,
    {:ouroboros, :lateral} => OuroborosWorkflowInvocation,
    :ouroboros_lateral => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :brownfield} => OuroborosWorkflowInvocation,
    {:ouroboros, :brownfield} => OuroborosWorkflowInvocation,
    :ouroboros_brownfield => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :cancel} => OuroborosDirectInvocation,
    {:ouroboros, :cancel} => OuroborosDirectInvocation,
    :ouroboros_cancel => OuroborosDirectInvocation,
    {:ouroboros_workflow, :resume_session} => OuroborosDirectInvocation,
    {:ouroboros, :resume_session} => OuroborosDirectInvocation,
    :ouroboros_resume_session => OuroborosDirectInvocation,
    {:ouroboros_workflow, :update} => OuroborosDirectInvocation,
    {:ouroboros, :update} => OuroborosDirectInvocation,
    :ouroboros_update => OuroborosDirectInvocation,
    {:ouroboros_workflow, :setup} => OuroborosDirectInvocation,
    {:ouroboros, :setup} => OuroborosDirectInvocation,
    :ouroboros_setup => OuroborosDirectInvocation,
    {:ouroboros_workflow, :publish} => OuroborosDirectInvocation,
    {:ouroboros, :publish} => OuroborosDirectInvocation,
    :ouroboros_publish => OuroborosDirectInvocation,
    {:ouroboros_workflow, :welcome} => OuroborosDirectInvocation,
    {:ouroboros, :welcome} => OuroborosDirectInvocation,
    :ouroboros_welcome => OuroborosDirectInvocation,
    {:ouroboros_workflow, :tutorial} => OuroborosDirectInvocation,
    {:ouroboros, :tutorial} => OuroborosDirectInvocation,
    :ouroboros_tutorial => OuroborosDirectInvocation,
    {:ouroboros_workflow, :help} => OuroborosDirectInvocation,
    {:ouroboros, :help} => OuroborosDirectInvocation,
    :ouroboros_help => OuroborosDirectInvocation
  }

  @type callbacks :: %{
          required(:enqueue_failure) => (pid(), String.t(), term() -> :ok),
          required(:run_interview_session) => (pid(), keyword() -> :ok),
          required(:production_parent_call) => (pid(), map(), String.t() -> function()),
          required(:mcp_url) => (-> String.t())
        }

  @doc false
  @spec adapter_registry() :: map()
  def adapter_registry, do: @ouroboros_adapters

  @spec handle_prompt(pid(), map(), map(), map(), callbacks()) :: :ok
  def handle_prompt(agent, runtime, task_request, input_event, callbacks)
      when is_pid(agent) and is_map(callbacks) do
    if ouroboros_route?(task_request) do
      parent_call_id = parent_call_id(task_request)
      workflow_run_id = "workflow-run:" <> parent_call_id

      LoopBindingEventFlow.enqueue(
        agent,
        WorkflowHarness.run_started_event(parent_call_id, task_request, run_id: workflow_run_id)
      )

      if interview_task?(task_request),
        do: InterviewProgress.mark_dispatching(agent, task_request, parent_call_id)

      spawn(fn ->
        dispatch_workflow(
          agent,
          runtime,
          task_request,
          input_event,
          parent_call_id,
          workflow_run_id,
          callbacks
        )
      end)
    end

    :ok
  end

  @spec ouroboros_route?(map()) :: boolean()
  def ouroboros_route?(%{routing_decision: %{execution_route: :ouroboros_workflow}}), do: true
  def ouroboros_route?(_task_request), do: false

  @spec interview_task?(map()) :: boolean()
  def interview_task?(%{routing_decision: %{adapter_route: :interview}}), do: true
  def interview_task?(_task_request), do: false

  @spec direct_task?(map()) :: boolean()
  def direct_task?(%{routing_decision: %{adapter_route: adapter_route}}) do
    adapter_route in [
      :cancel,
      :resume_session,
      :update,
      :setup,
      :publish,
      :welcome,
      :tutorial,
      :help
    ]
  end

  def direct_task?(_task_request), do: false

  @spec parent_call_id(map()) :: String.t()
  def parent_call_id(task_request), do: "parent-" <> to_string(task_request.id)

  @spec workflow_context(pid()) :: map()
  def workflow_context(agent) when is_pid(agent) do
    Agent.get(agent, fn state ->
      interview = state.interview || %{}
      workflow = Map.get(state, :workflow, %{})

      %{
        latest_interview_session_id: Map.get(interview, :session_id),
        latest_interview_ambiguity: Map.get(interview, :ambiguity),
        latest_seed_path: Map.get(workflow, :latest_seed_path),
        latest_seed_content: Map.get(workflow, :latest_seed_content),
        latest_job_id: Map.get(workflow, :latest_job_id),
        latest_auto_session_id: Map.get(workflow, :latest_auto_session_id),
        latest_workflow_session_id: Map.get(workflow, :latest_workflow_session_id),
        latest_execution_id: Map.get(workflow, :latest_execution_id),
        latest_lineage_id: Map.get(workflow, :latest_lineage_id),
        latest_evaluation_artifact: Map.get(workflow, :latest_evaluation_artifact),
        latest_problem_context: Map.get(workflow, :latest_problem_context),
        latest_current_approach: Map.get(workflow, :latest_current_approach),
        latest_failed_attempts: Map.get(workflow, :latest_failed_attempts)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  @spec input_event_model(map()) :: Model.t() | nil
  def input_event_model(%{active_model: %Model{} = model}), do: model
  def input_event_model(%{"active_model" => %Model{} = model}), do: model
  def input_event_model(_event), do: nil

  @spec project_dir(map() | term()) :: Path.t()
  def project_dir(runtime) when is_map(runtime),
    do: Map.get(runtime, :project_dir) || File.cwd!()

  def project_dir(_runtime), do: File.cwd!()

  defp dispatch_workflow(
         agent,
         runtime,
         task_request,
         input_event,
         parent_call_id,
         workflow_run_id,
         callbacks
       ) do
    model = input_event_model(input_event) || Catalog.default()

    context =
      if direct_task?(task_request) do
        %{
          cwd: project_dir(runtime),
          workflow_run_id: workflow_run_id
        }
      else
        {:ok, mcp_url} = McpDaemonBinding.ensure(agent, model)

        %{
          streamable_http_url: mcp_url,
          workflow_run_id: workflow_run_id,
          mcp_invoker:
            transport_invoker(agent, runtime, parent_call_id, workflow_run_id, model, callbacks)
        }
      end

    Dispatcher.dispatch(task_request,
      adapters: adapter_registry(),
      context:
        context
        |> Map.merge(%{
          request_id: "req-" <> to_string(task_request.id),
          parent_call_id: parent_call_id,
          workflow_run_id: workflow_run_id,
          cwd: project_dir(runtime)
        })
        |> Map.merge(workflow_context(agent))
    )
    |> case do
      {:ok, _invocation} ->
        :ok

      {:error, reason} ->
        LoopBindingEventFlow.enqueue(agent, WorkflowHarness.failure_event(parent_call_id, reason))
        callbacks.enqueue_failure.(agent, parent_call_id, {:dispatch_failed, reason})
    end
  rescue
    exception ->
      LoopBindingEventFlow.enqueue(
        agent,
        WorkflowHarness.failure_event(
          "parent-" <> to_string(task_request.id),
          {:dispatch_exception, Exception.message(exception)}
        )
      )

      callbacks.enqueue_failure.(
        agent,
        "parent-" <> to_string(task_request.id),
        {:dispatch_exception, Exception.message(exception)}
      )
  end

  defp transport_invoker(agent, runtime, parent_call_id, workflow_run_id, model, callbacks) do
    fn payload, _transport_options ->
      start_relay(agent, runtime, parent_call_id, workflow_run_id, payload, model, callbacks)
      {:ok, %{parent_call_id: parent_call_id}}
    end
  end

  defp start_relay(agent, runtime, parent_call_id, workflow_run_id, payload, model, callbacks) do
    if interview_payload?(payload) do
      spawn(fn ->
        callbacks.run_interview_session.(
          agent,
          parent_call_id: parent_call_id,
          initial_payload: payload,
          parent_call_fun: callbacks.production_parent_call.(agent, runtime, parent_call_id),
          model: model,
          workflow_run_id: workflow_run_id,
          project_dir: project_dir(runtime)
        )
      end)
    else
      spawn(fn ->
        WorkflowRelay.run(
          agent,
          runtime,
          parent_call_id,
          payload,
          project_dir(runtime),
          callbacks.mcp_url.(),
          workflow_run_id: workflow_run_id
        )
      end)
    end
  end

  defp interview_payload?(payload) when is_map(payload) do
    get_in(payload, ["params", "name"]) == "ouroboros_interview"
  end

  defp interview_payload?(_payload), do: false
end
