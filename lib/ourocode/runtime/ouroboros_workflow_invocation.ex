defmodule Ourocode.Runtime.OuroborosWorkflowInvocation do
  @moduledoc """
  Builds MCP requests for non-interview Ouroboros workflow shortcuts.

  `ooo seed` continues from the latest completed interview session and calls
  `ouroboros_generate_seed`. `ooo run` executes a seed via the background
  `ouroboros_start_execute_seed` tool so the prompt loop stays responsive.
  """

  @behaviour Ourocode.Runtime.Adapter

  alias Ourocode.TaskRequest

  @seed_tool "ouroboros_generate_seed"
  @run_tool "ouroboros_start_execute_seed"
  @default_method "tools/call"
  @client_gates ["seed_ready_acceptance_guard", "restate_goal_approved"]

  @type invocation :: %{
          required(:type) => :ouroboros_workflow_invocation,
          required(:status) => :ready | :invoked,
          required(:task_request_id) => String.t(),
          required(:adapter_route) => :seed | :run,
          required(:mcp_tool) => String.t(),
          required(:request_payload) => map(),
          optional(:result) => term()
        }

  @impl true
  @spec execute(TaskRequest.t(), map()) :: {:ok, invocation()} | {:error, term()}
  def execute(%TaskRequest{} = task_request, context) when is_map(context) do
    with {:ok, adapter_route} <- adapter_route(task_request, context),
         {:ok, request_payload} <- build_request_payload(task_request, context, adapter_route),
         {:ok, status, result} <- maybe_invoke(request_payload, context) do
      {:ok,
       %{
         type: :ouroboros_workflow_invocation,
         status: status,
         task_request_id: to_string(task_request.id),
         adapter_route: adapter_route,
         mcp_tool: get_in(request_payload, ["params", "name"]),
         request_payload: request_payload,
         result: result
       }}
    end
  end

  def execute(_task_request, _context), do: {:error, :invalid_task_request}

  @doc false
  @spec build_request_payload(TaskRequest.t(), map(), :seed | :run) ::
          {:ok, map()} | {:error, term()}
  def build_request_payload(%TaskRequest{} = task_request, context, :seed) do
    with {:ok, session_id} <- seed_session_id(task_request, context) do
      arguments =
        %{
          "session_id" => session_id,
          "client_gates" => @client_gates
        }
        |> maybe_put("ambiguity_score", Map.get(context, :latest_interview_ambiguity))

      {:ok, payload(task_request, context, @seed_tool, arguments)}
    end
  end

  def build_request_payload(%TaskRequest{} = task_request, context, :run) do
    with {:ok, seed_path} <- run_seed_path(task_request, context) do
      arguments =
        %{
          "seed_path" => seed_path,
          "cwd" => Map.get(context, :cwd) || File.cwd!(),
          "idempotency_key" => "ourocode-run-" <> to_string(task_request.id)
        }
        |> maybe_put("session_id", explicit_session_id(task_request.task_input))
        |> maybe_put("model_tier", explicit_model_tier(task_request.task_input))
        |> maybe_put("skip_qa", explicit_skip_qa(task_request.task_input))

      {:ok, payload(task_request, context, @run_tool, arguments)}
    end
  end

  def build_request_payload(_task_request, _context, adapter_route),
    do: {:error, {:unsupported_ouroboros_workflow_action, adapter_route}}

  defp adapter_route(%TaskRequest{routing_decision: %{adapter_route: route}}, _context)
       when route in [:seed, :run],
       do: {:ok, route}

  defp adapter_route(%TaskRequest{routing_decision: routing_decision}, _context),
    do:
      {:error,
       {:unsupported_ouroboros_workflow_action, Map.get(routing_decision, :adapter_route)}}

  defp seed_session_id(%TaskRequest{task_input: text}, context) do
    case explicit_session_id(text) || Map.get(context, :latest_interview_session_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _none -> {:error, :missing_interview_session_id}
    end
  end

  defp run_seed_path(%TaskRequest{task_input: text}, context) do
    case explicit_seed_path(text) || Map.get(context, :latest_seed_path) ||
           latest_seed_file(context) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _none -> {:error, :missing_seed_path}
    end
  end

  defp payload(%TaskRequest{} = task_request, context, tool, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => request_id(task_request, context, tool),
      "method" => @default_method,
      "params" => %{"name" => tool, "arguments" => arguments}
    }
  end

  defp request_id(%TaskRequest{id: id}, context, tool) do
    Map.get(context, :request_id, tool <> "-" <> to_string(id))
    |> to_string()
  end

  defp maybe_invoke(request_payload, context) do
    case Map.get(context, :mcp_invoker) do
      nil ->
        {:ok, :ready, nil}

      invoker when is_function(invoker, 2) ->
        case invoker.(request_payload, []) do
          {:ok, result} -> {:ok, :invoked, result}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:invalid_mcp_invoker_result, other}}
        end

      other ->
        {:error, {:invalid_mcp_invoker, other}}
    end
  end

  defp explicit_session_id(text) when is_binary(text) do
    case Regex.run(~r/(?:session[_\s-]?id=|session\s+)([A-Za-z0-9_.-]+)/i, text) do
      [_, id] -> id
      _none -> nil
    end
  end

  defp explicit_seed_path(text) when is_binary(text) do
    case Regex.run(~r/(?:seed[_\s-]?path=|(?:^|\s))([^\s]+\.ya?ml)\b/i, text) do
      [_, path] -> path
      _none -> nil
    end
  end

  defp explicit_model_tier(text) when is_binary(text) do
    case Regex.run(~r/\b(?:model[_\s-]?tier=|tier\s+)(small|medium|large)\b/i, text) do
      [_, tier] -> String.downcase(tier)
      _none -> nil
    end
  end

  defp explicit_skip_qa(text) when is_binary(text) do
    if String.match?(String.downcase(text), ~r/\b(skip[_\s-]?qa|no[_\s-]?qa)\b/),
      do: true,
      else: nil
  end

  defp latest_seed_file(context) do
    dirs =
      Map.get(context, :seed_search_dirs) ||
        [Map.get(context, :cwd) || File.cwd!(), Path.expand("~/.ouroboros/seeds")]

    dirs
    |> Enum.flat_map(fn dir ->
      dir = Path.expand(dir)
      Path.wildcard(Path.join(dir, "seed_*.yaml")) ++ Path.wildcard(Path.join(dir, "seed_*.yml"))
    end)
    |> Enum.reject(&String.ends_with?(&1, "_repaired.yaml"))
    |> Enum.map(fn path -> {File.stat(path), path} end)
    |> Enum.filter(fn
      {{:ok, _stat}, _path} -> true
      _other -> false
    end)
    |> Enum.max_by(fn {{:ok, stat}, _path} -> stat.mtime end, fn -> nil end)
    |> case do
      nil -> nil
      {_stat, path} -> path
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
