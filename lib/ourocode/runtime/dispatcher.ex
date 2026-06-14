defmodule Ourocode.Runtime.Dispatcher do
  @moduledoc """
  Dispatches parsed internal runtime routes to adapter modules.

  `Ourocode.TaskRequest` decides the route from natural language or advanced
  shortcuts. This module keeps that routing decision executable by resolving the
  route to a runtime adapter and passing along a small dispatch context.

  Ouroboros workflow routes may also carry an `:adapter_route` such as
  `:interview`, `:seed`, `:evolve`, or `:ralph`. Dispatch resolves those to
  action-specific adapter registry keys before falling back to the generic
  Ouroboros workflow adapter.
  """

  alias Ourocode.TaskRequest
  alias Ourocode.Runtime.ChildSessionActionDispatch
  alias Ourocode.Runtime.ChildPaneSteering
  alias Ourocode.Runtime.Dispatcher.RouteResolution
  alias Ourocode.Runtime.ExternalCommandGuard

  @type adapter_registry ::
          %{optional(atom() | {atom(), atom()}) => module()}
          | [
              {atom() | {atom(), atom()}, module()}
            ]
  @type dispatch_context :: %{
          required(:execution_route) => atom(),
          required(:runtime_source) => atom(),
          required(:transport) => atom(),
          required(:routing_decision) => TaskRequest.routing_decision(),
          optional(atom()) => term()
        }

  @doc """
  Dispatches a task request to its configured route adapter.

  Adapter registry keys may be route-level (`:runtime`, `:ouroboros_workflow`,
  `:mcp_flow`), runtime-source-specific, transport-specific for MCP routes, or
  Ouroboros workflow-action-specific:

    * `{:mcp_flow, :stdio}`
    * `{:mcp, :streamable_http}`
    * `:mcp_sse`

    * `{:ouroboros_workflow, :interview}`
    * `{:ouroboros, :interview}`
    * `:ouroboros_interview`

  Transport-specific MCP adapters take precedence over generic MCP adapters.
  Action-specific Ouroboros adapters take precedence over the generic
  `:ouroboros_workflow` adapter. Source-specific adapters take precedence for
  explicit runtime shortcuts, while `:auto` falls back to the route-level
  `:runtime` adapter.
  """
  @spec dispatch(TaskRequest.t(), keyword() | map()) ::
          {:ok, term()} | {:error, term()}
  def dispatch(task_request, options \\ [])

  def dispatch(%TaskRequest{} = task_request, options) do
    with {:ok, routing_decision} <- fetch_routing_decision(task_request),
         :ok <- RouteResolution.validate_decision(routing_decision),
         {:ok, adapter} <-
           RouteResolution.resolve_adapter(
             task_request,
             routing_decision,
             adapter_registry(options)
           ),
         :ok <- RouteResolution.ensure_adapter(adapter) do
      adapter.execute(task_request, dispatch_context(routing_decision, options))
    end
  end

  def dispatch(_task_request, _options), do: {:error, :invalid_task_request}

  @doc """
  Delivers a terminal steering input event to the currently focused child pane.

  The terminal input layer serializes natural-language prompt text as a
  `:pane_directed_steering_message`. This function is the runtime dispatch
  boundary: it resolves that message against the current pane model and hands a
  JSON wire payload to the configured child-pane dispatcher.

  Production wiring status: the builtin `/interrupt` and `/cancel` actions are
  wired end-to-end (`LoopBindings.attach/1` injects
  `ChildSessionCancelDispatcher` via `:command_dispatch_options`), but no
  production caller invokes this free-text steering function yet — the
  terminal currently only echoes steering text into the local pane model
  (`Ourocode.Terminal.SteeringPane`), and the live Ouroboros MCP server
  exposes no tool that accepts steering text for a running job. The seam stays
  here so a future server-side steering tool only needs a
  `:child_pane_dispatcher` option.
  """
  @spec dispatch_steering_message(map(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def dispatch_steering_message(input_event, options \\ [])

  def dispatch_steering_message(%{} = input_event, options) do
    ChildPaneSteering.dispatch(input_event, options)
  end

  def dispatch_steering_message(_input_event, _options),
    do: {:error, :invalid_steering_input_event}

  @doc """
  Dispatches the builtin interrupt action to the currently focused child session.

  The focused child is resolved from the current runtime focus state and pane
  model at dispatch time. The command event may carry stale target metadata, but
  delivery is made only to the resolved focused child pane.
  """
  @spec dispatch_interrupt_action(map(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def dispatch_interrupt_action(command_event, options \\ [])

  def dispatch_interrupt_action(%{} = command_event, options) do
    ChildSessionActionDispatch.dispatch_interrupt(command_event, options)
  end

  def dispatch_interrupt_action(_command_event, _options),
    do: {:error, :invalid_interrupt_command_event}

  @doc """
  Dispatches the builtin cancel action to the currently focused child session.

  The focused child is resolved at dispatch time so stale command metadata
  cannot cancel a sibling pane after focus has moved.
  """
  @spec dispatch_cancel_action(map(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def dispatch_cancel_action(command_event, options \\ [])

  def dispatch_cancel_action(%{} = command_event, options) do
    ChildSessionActionDispatch.dispatch_cancel(command_event, options)
  end

  def dispatch_cancel_action(_command_event, _options),
    do: {:error, :invalid_cancel_command_event}

  @doc """
  Builds the user-visible error returned when no internal flow can handle a task.
  """
  @spec unsupported_task_error(TaskRequest.t(), TaskRequest.routing_decision(), list()) :: map()
  def unsupported_task_error(%TaskRequest{} = task_request, routing_decision, adapter_keys)
      when is_map(routing_decision) and is_list(adapter_keys) do
    RouteResolution.unsupported_task_error(task_request, routing_decision, adapter_keys)
  end

  defp fetch_routing_decision(%TaskRequest{routing_decision: decision}) when is_map(decision) do
    {:ok, decision}
  end

  defp fetch_routing_decision(_task_request), do: {:error, :missing_routing_decision}

  defp adapter_registry(options) do
    options
    |> option(:adapters, %{})
    |> Map.new()
  end

  defp dispatch_context(routing_decision, options) do
    options
    |> option(:context, %{})
    |> Map.new()
    |> Map.merge(%{
      execution_route: Map.fetch!(routing_decision, :execution_route),
      runtime_source: Map.fetch!(routing_decision, :runtime_source),
      transport: Map.fetch!(routing_decision, :transport),
      routing_decision: routing_decision,
      external_command_runner: guarded_external_command_runner(options)
    })
    |> maybe_put_adapter_route(routing_decision)
  end

  defp guarded_external_command_runner(options) do
    options
    |> option(:external_command_runner, nil)
    |> ExternalCommandGuard.guarded_runner()
  end

  defp maybe_put_adapter_route(context, %{adapter_route: adapter_route}) do
    Map.put(context, :adapter_route, adapter_route)
  end

  defp maybe_put_adapter_route(context, _routing_decision), do: context

  defp option(options, key, default) when is_map(options), do: Map.get(options, key, default)
  defp option(options, key, default) when is_list(options), do: Keyword.get(options, key, default)
end
