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

  alias Ourocode.{Json, TaskRequest}
  alias Ourocode.Runtime.FocusState

  @supported_routes [:runtime, :ouroboros_workflow, :mcp_flow]
  @supported_runtime_sources [:auto, :codex, :opencode, :claude_code, :ouroboros, :mcp]
  @supported_transports [:auto, :stdio, :streamable_http, :sse]
  @supported_adapter_routes [:interview, :seed, :run, :evolve, :ralph, :workflow]
  @forbidden_external_commands MapSet.new(["codex", "claude", "claude-code"])
  @shell_commands MapSet.new(["bash", "cmd", "fish", "powershell", "pwsh", "sh", "zsh"])

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
         :ok <- validate_routing_decision(routing_decision),
         {:ok, adapter} <-
           resolve_adapter(task_request, routing_decision, adapter_registry(options)),
         :ok <- ensure_adapter(adapter) do
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
  """
  @spec dispatch_steering_message(map(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def dispatch_steering_message(input_event, options \\ [])

  def dispatch_steering_message(%{} = input_event, options) do
    options = Map.new(options)
    context = options |> option(:context, %{}) |> Map.new()

    with :ok <- ensure_child_steering_event(input_event),
         {:ok, steering_message} <- fetch_steering_message(input_event),
         {:ok, pane} <-
           resolve_focused_child_pane(input_event, steering_message, options, context),
         {:ok, serialized_message, decoded_message} <-
           serialize_steering_message(input_event, steering_message, pane),
         {:ok, delivery_result} <-
           deliver_steering_message(pane, serialized_message, decoded_message, options, context) do
      {:ok,
       %{
         pane: pane,
         serialized_message: serialized_message,
         decoded_message: decoded_message,
         delivery_result: delivery_result
       }}
    end
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
    options = Map.new(options)
    context = options |> option(:context, %{}) |> Map.new()
    focus_state = option(options, :focus_state, Map.get(context, :focus_state, FocusState.new()))
    pane_model = option(options, :pane_model, Map.get(context, :pane_model, %{}))

    with :ok <- ensure_interrupt_action(command_event),
         {:ok, focused_child} <- FocusState.focused_child_session(focus_state, pane_model),
         {:ok, serialized_request, decoded_request} <-
           serialize_interrupt_request(command_event, focused_child),
         {:ok, delivery_result} <-
           deliver_interrupt_request(
             focused_child.pane,
             serialized_request,
             decoded_request,
             options,
             context
           ) do
      {:ok,
       %{
         focused_child: Map.delete(focused_child, :pane),
         pane: focused_child.pane,
         serialized_request: serialized_request,
         decoded_request: decoded_request,
         delivery_result: delivery_result
       }}
    end
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
    options = Map.new(options)
    context = options |> option(:context, %{}) |> Map.new()
    focus_state = option(options, :focus_state, Map.get(context, :focus_state, FocusState.new()))
    pane_model = option(options, :pane_model, Map.get(context, :pane_model, %{}))

    with :ok <- ensure_cancel_action(command_event),
         {:ok, focused_child} <- FocusState.focused_child_session(focus_state, pane_model),
         {:ok, serialized_request, decoded_request} <-
           serialize_cancel_request(command_event, focused_child),
         {:ok, delivery_result} <-
           deliver_cancel_request(
             focused_child.pane,
             serialized_request,
             decoded_request,
             options,
             context
           ) do
      {:ok,
       %{
         focused_child: Map.delete(focused_child, :pane),
         pane: focused_child.pane,
         serialized_request: serialized_request,
         decoded_request: decoded_request,
         delivery_result: delivery_result
       }}
    end
  end

  def dispatch_cancel_action(_command_event, _options),
    do: {:error, :invalid_cancel_command_event}

  @doc """
  Builds the user-visible error returned when no internal flow can handle a task.
  """
  @spec unsupported_task_error(TaskRequest.t(), TaskRequest.routing_decision(), list()) :: map()
  def unsupported_task_error(%TaskRequest{} = task_request, routing_decision, adapter_keys)
      when is_map(routing_decision) and is_list(adapter_keys) do
    %{
      code: :unsupported_task,
      message: unsupported_task_message(routing_decision),
      task_input: task_request.task_input,
      routing_decision: routing_decision,
      attempted_adapter_keys: adapter_keys
    }
  end

  defp fetch_routing_decision(%TaskRequest{routing_decision: decision}) when is_map(decision) do
    {:ok, decision}
  end

  defp fetch_routing_decision(_task_request), do: {:error, :missing_routing_decision}

  defp validate_routing_decision(decision) do
    with {:ok, execution_route} <- required_atom(decision, :execution_route),
         {:ok, kind} <- required_atom(decision, :kind),
         {:ok, runtime_source} <- required_atom(decision, :runtime_source),
         {:ok, transport} <- required_atom(decision, :transport),
         :ok <- ensure_supported(:execution_route, execution_route, @supported_routes),
         :ok <- ensure_supported(:kind, kind, @supported_routes),
         :ok <- ensure_matching_route(kind, execution_route),
         :ok <- ensure_supported(:runtime_source, runtime_source, @supported_runtime_sources),
         :ok <- ensure_supported(:transport, transport, @supported_transports),
         :ok <- validate_adapter_route(decision) do
      :ok
    end
  end

  defp required_atom(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_atom(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_routing_decision, key, value}}
      :error -> {:error, {:missing_routing_decision_field, key}}
    end
  end

  defp ensure_supported(field, value, supported) do
    if Enum.member?(supported, value) do
      :ok
    else
      {:error, {:unsupported_routing_decision, field, value}}
    end
  end

  defp ensure_matching_route(route, route), do: :ok

  defp ensure_matching_route(kind, execution_route) do
    {:error, {:route_mismatch, kind, execution_route}}
  end

  defp validate_adapter_route(%{
         execution_route: :ouroboros_workflow,
         adapter_route: adapter_route
       }) do
    ensure_supported(:adapter_route, adapter_route, @supported_adapter_routes)
  end

  defp validate_adapter_route(%{adapter_route: adapter_route}) do
    {:error, {:unexpected_adapter_route, adapter_route}}
  end

  defp validate_adapter_route(_decision), do: :ok

  defp adapter_registry(options) do
    options
    |> option(:adapters, %{})
    |> Map.new()
  end

  defp resolve_adapter(task_request, routing_decision, adapters) do
    adapter_keys = adapter_keys(routing_decision)

    case find_adapter(adapters, adapter_keys) do
      nil -> {:error, unsupported_task_error(task_request, routing_decision, adapter_keys)}
      adapter -> {:ok, adapter}
    end
  end

  defp unsupported_task_message(%{
         execution_route: execution_route,
         runtime_source: runtime_source,
         transport: transport
       }) do
    route = execution_route |> Atom.to_string() |> String.replace("_", " ")
    runtime = runtime_source |> Atom.to_string() |> String.replace("_", " ")
    transport_label = transport |> Atom.to_string() |> String.replace("_", " ")

    "Unsupported task: no internal #{route} flow is available for #{runtime} using #{transport_label}."
  end

  defp unsupported_task_message(_routing_decision) do
    "Unsupported task: no internal flow is available for this request."
  end

  defp adapter_keys(:runtime, :auto), do: [:runtime]
  defp adapter_keys(route, runtime_source), do: [runtime_source, route]

  defp adapter_keys(%{
         execution_route: :ouroboros_workflow,
         runtime_source: :ouroboros,
         adapter_route: adapter_route
       }) do
    [
      {:ouroboros_workflow, adapter_route},
      {:ouroboros, adapter_route},
      :"ouroboros_#{adapter_route}",
      :ouroboros,
      :ouroboros_workflow
    ]
  end

  defp adapter_keys(%{execution_route: :mcp_flow, runtime_source: :mcp, transport: :auto}) do
    [:mcp, :mcp_flow]
  end

  defp adapter_keys(%{execution_route: :mcp_flow, runtime_source: :mcp, transport: transport}) do
    [
      {:mcp_flow, transport},
      {:mcp, transport},
      :"mcp_#{transport}",
      :mcp,
      :mcp_flow
    ]
  end

  defp adapter_keys(%{execution_route: route, runtime_source: runtime_source}) do
    adapter_keys(route, runtime_source)
  end

  defp find_adapter(adapters, keys) do
    Enum.find_value(keys, &Map.get(adapters, &1))
  end

  defp ensure_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute, 2) do
      :ok
    else
      {:error, {:invalid_adapter, adapter}}
    end
  end

  defp ensure_adapter(adapter), do: {:error, {:invalid_adapter, adapter}}

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
    delegate =
      option(options, :external_command_runner, &external_command_runner_not_configured/3)

    fn command, args, runner_options ->
      with :ok <- ensure_external_command_allowed(command, args) do
        delegate.(command, args, runner_options)
      end
    end
  end

  defp external_command_runner_not_configured(_command, _args, _runner_options) do
    {:error, :external_command_runner_not_configured}
  end

  defp ensure_external_command_allowed(command, args) when is_binary(command) and is_list(args) do
    cond do
      forbidden_command?(command) ->
        {:error, {:forbidden_external_command, executable_name(command)}}

      shell_command?(command) and shell_args_include_forbidden_command?(args) ->
        {:error, {:forbidden_external_command, :shell_wrapped_agent_command}}

      true ->
        :ok
    end
  end

  defp ensure_external_command_allowed(command, args) do
    {:error, {:invalid_external_command_request, command, args}}
  end

  defp forbidden_command?(command) do
    MapSet.member?(@forbidden_external_commands, executable_name(command))
  end

  defp shell_command?(command) do
    MapSet.member?(@shell_commands, executable_name(command))
  end

  defp executable_name(command) do
    command
    |> Path.basename()
    |> String.downcase()
  end

  defp shell_args_include_forbidden_command?(args) do
    args
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(fn arg ->
      Enum.any?(@forbidden_external_commands, &command_token_present?(arg, &1))
    end)
  end

  defp command_token_present?(arg, command) do
    Regex.match?(~r/(^|[^A-Za-z0-9_.-])#{Regex.escape(command)}([^A-Za-z0-9_.-]|$)/, arg)
  end

  defp maybe_put_adapter_route(context, %{adapter_route: adapter_route}) do
    Map.put(context, :adapter_route, adapter_route)
  end

  defp maybe_put_adapter_route(context, _routing_decision), do: context

  defp ensure_child_steering_event(input_event) do
    case map_value(input_event, :steering_target) do
      :child -> :ok
      "child" -> :ok
      other -> {:error, {:unsupported_steering_target, other}}
    end
  end

  defp fetch_steering_message(input_event) do
    case map_value(input_event, :steering_message) do
      %{type: :pane_directed_steering_message} = message -> {:ok, message}
      %{"type" => "pane_directed_steering_message"} = message -> {:ok, message}
      %{"type" => :pane_directed_steering_message} = message -> {:ok, message}
      %{type: "pane_directed_steering_message"} = message -> {:ok, message}
      _message -> {:error, :missing_pane_directed_steering_message}
    end
  end

  defp resolve_focused_child_pane(input_event, steering_message, options, context) do
    pane_model = option(options, :pane_model, Map.get(context, :pane_model, %{}))
    target_pane_id = steering_target_pane_id(input_event, steering_message, context)

    with {:ok, pane_id} <- require_target_pane_id(target_pane_id),
         {:ok, pane} <- pane_from_model(pane_model, pane_id),
         :ok <- ensure_child_pane(pane, pane_id) do
      {:ok, pane}
    end
  end

  defp steering_target_pane_id(input_event, steering_message, context) do
    focus_state =
      map_value(context, :focus_state) ||
        map_value(input_event, :focus_state) ||
        %{}

    map_value(focus_state, :steering_target_pane_id) ||
      map_value(focus_state, :focused_pane) ||
      map_value(input_event, :steering_target_pane_id) ||
      map_value(input_event, :focused_pane) ||
      map_value(steering_message, :target_pane_id)
  end

  defp require_target_pane_id(pane_id) when is_binary(pane_id) and pane_id != "",
    do: {:ok, pane_id}

  defp require_target_pane_id(pane_id) when is_atom(pane_id), do: {:ok, pane_id}
  defp require_target_pane_id(_pane_id), do: {:error, :missing_steering_target_pane_id}

  defp pane_from_model(%{panes: panes}, pane_id) when is_map(panes) do
    case Map.get(panes, pane_id) || Map.get(panes, pane_key(pane_id)) ||
           pane_by_id(panes, pane_id) do
      nil -> {:error, {:focused_child_pane_not_found, pane_id}}
      pane when is_map(pane) -> {:ok, Map.put_new(pane, :id, pane_id)}
      pane -> {:error, {:invalid_focused_child_pane, pane}}
    end
  end

  defp pane_from_model(%{"panes" => panes}, pane_id) when is_map(panes) do
    pane_from_model(%{panes: panes}, pane_id)
  end

  defp pane_from_model(_pane_model, pane_id),
    do: {:error, {:focused_child_pane_not_found, pane_id}}

  defp pane_by_id(panes, pane_id) do
    Enum.find_value(panes, fn
      {_key, %{id: ^pane_id} = pane} -> pane
      {_key, %{"id" => ^pane_id} = pane} -> pane
      {_key, _pane} -> nil
    end)
  end

  defp ensure_child_pane(pane, pane_id) do
    kind = map_value(pane, :kind)

    cond do
      kind in [:child_session, "child_session", :child_sessions, "child_sessions"] ->
        :ok

      child_pane_id?(pane_id) ->
        :ok

      true ->
        {:error, {:focused_pane_is_not_child, pane_id, kind}}
    end
  end

  defp child_pane_id?(pane_id) when is_binary(pane_id) do
    String.starts_with?(pane_id, ["child-", "child:", "child-session:", "child-pane:"])
  end

  defp child_pane_id?(_pane_id), do: false

  defp serialize_steering_message(input_event, steering_message, pane) do
    resolved_pane_id = map_value(pane, :id)
    resolved_session_id = map_value(pane, :child_id) || map_value(pane, :session_id)
    resolved_kind = map_value(pane, :kind)

    decoded_message = %{
      type: "pane_directed_steering_message",
      content:
        string_value(
          map_value(steering_message, :content) || map_value(input_event, :steering_text)
        ),
      target_pane_id:
        string_value(
          resolved_pane_id ||
            map_value(steering_message, :target_pane_id) ||
            map_value(input_event, :steering_target_pane_id)
        ),
      target_session_id:
        string_value(
          resolved_session_id ||
            map_value(steering_message, :target_session_id) ||
            map_value(input_event, :steering_target_session_id)
        ),
      target_kind:
        string_value(
          resolved_kind ||
            map_value(steering_message, :target_kind) ||
            map_value(input_event, :steering_target_kind)
        ),
      task_request_id: string_value(map_value(input_event, :task_request_id)),
      task_input: string_value(map_value(input_event, :task_input)),
      focused_pane: string_value(map_value(input_event, :focused_pane)),
      steering_target: string_value(map_value(input_event, :steering_target)),
      source_event_seq: map_value(input_event, :event_seq),
      pane_id: string_value(resolved_pane_id),
      child_id: string_value(resolved_session_id)
    }

    {:ok, decoded_message |> Json.encode!() |> IO.iodata_to_binary(), decoded_message}
  end

  defp deliver_steering_message(pane, serialized_message, decoded_message, options, context) do
    dispatcher = option(options, :child_pane_dispatcher, nil)
    delivery_context = Map.merge(context, %{decoded_message: decoded_message})

    cond do
      is_function(dispatcher, 3) ->
        normalize_delivery_result(dispatcher.(pane, serialized_message, delivery_context))

      is_function(dispatcher, 2) ->
        normalize_delivery_result(dispatcher.(pane, serialized_message))

      true ->
        {:error, :child_pane_dispatcher_not_configured}
    end
  end

  defp normalize_delivery_result(:ok), do: {:ok, :ok}
  defp normalize_delivery_result({:ok, result}), do: {:ok, result}
  defp normalize_delivery_result({:error, reason}), do: {:error, reason}

  defp normalize_delivery_result(other),
    do: {:error, {:invalid_child_pane_dispatch_result, other}}

  defp ensure_interrupt_action(command_event) do
    command = map_value(command_event, :command)
    action = interrupt_action(command_event)

    cond do
      action in [:interrupt_focused_child, "interrupt_focused_child"] ->
        :ok

      command in ["/interrupt", "/stop-child"] ->
        :ok

      true ->
        {:error, {:unsupported_builtin_action, action || command}}
    end
  end

  defp interrupt_action(command_event) do
    run_spec = map_value(command_event, :run_spec) || %{}
    map_value(run_spec, :action) || map_value(command_event, :action)
  end

  defp ensure_cancel_action(command_event) do
    command = map_value(command_event, :command)
    action = cancel_action(command_event)

    cond do
      action in [:cancel_focused_child, "cancel_focused_child"] ->
        :ok

      command in ["/cancel", "/cancel-child"] ->
        :ok

      true ->
        {:error, {:unsupported_builtin_action, action || command}}
    end
  end

  defp cancel_action(command_event) do
    run_spec = map_value(command_event, :run_spec) || %{}
    map_value(run_spec, :action) || map_value(command_event, :action)
  end

  defp serialize_interrupt_request(command_event, focused_child) do
    pane = focused_child.pane
    command = map_value(command_event, :command)

    decoded_request = %{
      type: "child_session_interrupt_request",
      action: "interrupt",
      target_pane_id: string_value(focused_child.pane_id),
      target_session_id: string_value(focused_child.session_id),
      target_kind: string_value(focused_child.kind),
      child_id: string_value(focused_child.child_id),
      pane_id: string_value(map_value(pane, :id) || focused_child.pane_id),
      reason: interrupt_reason(command_event),
      source: "terminal_command",
      source_command: string_value(command),
      source_args: List.wrap(map_value(command_event, :args)),
      source_event_seq: map_value(command_event, :event_seq),
      occurred_at_ms:
        map_value(command_event, :occurred_at_ms) || System.system_time(:millisecond)
    }

    {:ok, decoded_request |> Json.encode!() |> IO.iodata_to_binary(), decoded_request}
  end

  defp serialize_cancel_request(command_event, focused_child) do
    pane = focused_child.pane
    command = map_value(command_event, :command)

    decoded_request = %{
      type: "child_session_cancel_request",
      action: "cancel",
      target_pane_id: string_value(focused_child.pane_id),
      target_session_id: string_value(focused_child.session_id),
      target_kind: string_value(focused_child.kind),
      child_id: string_value(focused_child.child_id),
      pane_id: string_value(map_value(pane, :id) || focused_child.pane_id),
      reason: cancel_reason(command_event),
      source: "terminal_command",
      source_command: string_value(command),
      source_args: List.wrap(map_value(command_event, :args)),
      source_event_seq: map_value(command_event, :event_seq),
      occurred_at_ms:
        map_value(command_event, :occurred_at_ms) || System.system_time(:millisecond)
    }

    {:ok, decoded_request |> Json.encode!() |> IO.iodata_to_binary(), decoded_request}
  end

  defp interrupt_reason(command_event) do
    args = List.wrap(map_value(command_event, :args))

    case Enum.join(args, " ") do
      "" -> "user_requested_interrupt"
      reason -> reason
    end
  end

  defp cancel_reason(command_event) do
    args = List.wrap(map_value(command_event, :args))

    case Enum.join(args, " ") do
      "" -> "user_requested_cancel"
      reason -> reason
    end
  end

  defp deliver_interrupt_request(pane, serialized_request, decoded_request, options, context) do
    dispatcher =
      option(options, :child_session_interrupt_dispatcher, nil) ||
        option(options, :child_pane_interrupt_dispatcher, nil)

    delivery_context = Map.merge(context, %{decoded_request: decoded_request})

    cond do
      is_function(dispatcher, 3) ->
        normalize_interrupt_delivery_result(
          dispatcher.(pane, serialized_request, delivery_context)
        )

      is_function(dispatcher, 2) ->
        normalize_interrupt_delivery_result(dispatcher.(pane, serialized_request))

      true ->
        {:error, :child_session_interrupt_dispatcher_not_configured}
    end
  end

  defp normalize_interrupt_delivery_result(:ok), do: {:ok, :ok}
  defp normalize_interrupt_delivery_result({:ok, result}), do: {:ok, result}
  defp normalize_interrupt_delivery_result({:error, reason}), do: {:error, reason}

  defp normalize_interrupt_delivery_result(other),
    do: {:error, {:invalid_child_session_interrupt_dispatch_result, other}}

  defp deliver_cancel_request(pane, serialized_request, decoded_request, options, context) do
    dispatcher =
      option(options, :child_session_cancel_dispatcher, nil) ||
        option(options, :child_pane_cancel_dispatcher, nil)

    delivery_context = Map.merge(context, %{decoded_request: decoded_request})

    cond do
      is_function(dispatcher, 3) ->
        normalize_cancel_delivery_result(dispatcher.(pane, serialized_request, delivery_context))

      is_function(dispatcher, 2) ->
        normalize_cancel_delivery_result(dispatcher.(pane, serialized_request))

      true ->
        {:error, :child_session_cancel_dispatcher_not_configured}
    end
  end

  defp normalize_cancel_delivery_result(:ok), do: {:ok, :ok}
  defp normalize_cancel_delivery_result({:ok, result}), do: {:ok, result}
  defp normalize_cancel_delivery_result({:error, reason}), do: {:error, reason}

  defp normalize_cancel_delivery_result(other),
    do: {:error, {:invalid_child_session_cancel_dispatch_result, other}}

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp pane_key(pane_id) when is_atom(pane_id), do: Atom.to_string(pane_id)
  defp pane_key(pane_id) when is_binary(pane_id), do: pane_id
  defp pane_key(pane_id), do: inspect(pane_id)

  defp string_value(nil), do: nil
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value), do: to_string(value)

  defp option(options, key, default) when is_map(options), do: Map.get(options, key, default)
  defp option(options, key, default) when is_list(options), do: Keyword.get(options, key, default)
end
