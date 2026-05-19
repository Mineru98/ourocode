defmodule Ourocode.Runtime.InterviewWorkflowInvocation do
  @moduledoc """
  Builds the initial MCP request for the Ouroboros interview workflow.

  The terminal input loop preserves the user's natural-language prompt in
  `Ourocode.TaskRequest.task_input`. This adapter turns that preserved text into
  the first `ouroboros_interview` MCP tools/call payload used by streamable HTTP
  UI requirements gathering.
  """

  @behaviour Ourocode.Runtime.Adapter

  alias Ourocode.TaskRequest

  @default_mcp_tool "ouroboros_interview"
  @default_method "tools/call"
  @default_transport :streamable_http

  @type json_rpc_payload :: %{
          required(String.t()) => term()
        }

  @type invocation :: %{
          required(:type) => :interview_workflow_invocation,
          required(:status) => :ready | :invoked,
          required(:task_request_id) => String.t(),
          required(:prompt_text) => String.t(),
          required(:transport) => :streamable_http,
          required(:mcp_tool) => String.t(),
          required(:request_payload) => json_rpc_payload(),
          optional(:result) => term()
        }

  @impl true
  @spec execute(TaskRequest.t(), map()) :: {:ok, invocation()} | {:error, term()}
  def execute(%TaskRequest{} = task_request, context) when is_map(context) do
    with :ok <- ensure_interview_route(task_request),
         {:ok, request_payload} <- build_initial_request_payload(task_request, context),
         {:ok, status, result} <- maybe_invoke(request_payload, context) do
      {:ok, invocation(task_request, context, request_payload, status, result)}
    end
  end

  def execute(_task_request, _context), do: {:error, :invalid_task_request}

  @doc """
  Constructs the streamable HTTP MCP tools/call payload for a new interview.
  """
  @spec build_initial_request_payload(TaskRequest.t(), map() | keyword()) ::
          {:ok, json_rpc_payload()} | {:error, term()}
  def build_initial_request_payload(task_request, context \\ %{})

  def build_initial_request_payload(%TaskRequest{} = task_request, context) do
    context = Map.new(context)

    with {:ok, prompt_text} <- preserved_prompt_text(task_request) do
      {:ok,
       %{
         "jsonrpc" => "2.0",
         "id" => request_id(task_request, context),
         "method" => @default_method,
         "params" => %{
           "name" => mcp_tool(context),
           "arguments" => interview_arguments(prompt_text, context)
         }
       }}
    end
  end

  def build_initial_request_payload(_task_request, _context), do: {:error, :invalid_task_request}

  @doc """
  Constructs the streamable HTTP MCP tools/call payload that returns one
  recorded answer to an in-flight interview session.

  Mirrors `build_initial_request_payload/2` (same `@default_method`,
  `mcp_tool`, and `request_id` resolution) but swaps the `arguments` shape to
  `%{"session_id" => id, "answer" => text}`. An optional `:last_question`
  context value is forwarded when present so the SKILL Restate reopen can
  attach a post-seed-ready correction to the exact local prompt.
  """
  @spec build_followup_request_payload(String.t(), String.t(), map() | keyword()) ::
          {:ok, json_rpc_payload()} | {:error, term()}
  def build_followup_request_payload(session_id, answer, context \\ %{})

  def build_followup_request_payload(session_id, answer, context)
      when is_binary(session_id) and session_id != "" and is_binary(answer) do
    context = Map.new(context)

    {:ok,
     %{
       "jsonrpc" => "2.0",
       "id" => followup_request_id(session_id, context),
       "method" => @default_method,
       "params" => %{
         "name" => mcp_tool(context),
         "arguments" => followup_arguments(session_id, answer, context)
       }
     }}
  end

  def build_followup_request_payload(_session_id, _answer, _context),
    do: {:error, :invalid_followup_request}

  defp followup_request_id(session_id, context) do
    context
    |> Map.get(:request_id, "interview-followup-" <> session_id)
    |> to_string()
  end

  defp followup_arguments(session_id, answer, context) do
    %{"session_id" => session_id, "answer" => answer}
    |> maybe_put_argument("last_question", Map.get(context, :last_question))
  end

  defp ensure_interview_route(%TaskRequest{
         routing_decision: %{
           execution_route: :ouroboros_workflow,
           runtime_source: :ouroboros,
           adapter_route: :interview
         }
       }) do
    :ok
  end

  defp ensure_interview_route(%TaskRequest{routing_decision: routing_decision}) do
    {:error, {:unsupported_interview_route, routing_decision}}
  end

  defp preserved_prompt_text(%TaskRequest{task_input: task_input})
       when is_binary(task_input) and byte_size(task_input) > 0 do
    {:ok, task_input}
  end

  defp preserved_prompt_text(_task_request), do: {:error, :missing_preserved_prompt_text}

  defp request_id(%TaskRequest{id: id}, context) do
    context
    |> Map.get(:request_id, "interview-" <> to_string(id))
    |> to_string()
  end

  defp mcp_tool(context) do
    context
    |> Map.get(:mcp_tool, @default_mcp_tool)
    |> to_string()
  end

  defp interview_arguments(prompt_text, context) do
    %{"initial_context" => prompt_text}
    |> maybe_put_argument("cwd", Map.get(context, :cwd))
  end

  defp maybe_put_argument(arguments, _key, nil), do: arguments
  defp maybe_put_argument(arguments, key, value), do: Map.put(arguments, key, value)

  defp maybe_invoke(request_payload, context) do
    case Map.get(context, :mcp_invoker) do
      nil ->
        {:ok, :ready, nil}

      invoker when is_function(invoker, 2) ->
        case invoker.(request_payload, transport_options(context)) do
          {:ok, result} -> {:ok, :invoked, result}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:invalid_mcp_invoker_result, other}}
        end

      other ->
        {:error, {:invalid_mcp_invoker, other}}
    end
  end

  defp transport_options(context) do
    %{
      transport: @default_transport,
      url: Map.get(context, :streamable_http_url),
      journal_path: Map.get(context, :journal_path)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp invocation(task_request, context, request_payload, status, result) do
    base = %{
      type: :interview_workflow_invocation,
      status: status,
      task_request_id: task_request.id,
      prompt_text: task_request.task_input,
      transport: @default_transport,
      mcp_tool: mcp_tool(context),
      request_payload: request_payload
    }

    if is_nil(result), do: base, else: Map.put(base, :result, result)
  end
end
