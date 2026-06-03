defmodule Ourocode.Runtime.OuroborosWorkflowInvocation do
  @moduledoc """
  Builds MCP requests for non-interview Ouroboros workflow shortcuts.

  `ooo seed` continues from the latest completed interview session and calls
  `ouroboros_generate_seed`. `ooo run` executes a seed via the background
  `ouroboros_start_execute_seed` tool so the prompt loop stays responsive.
  `ooo auto` starts the background auto pipeline with `ouroboros_start_auto`.
  Other MCP-backed workflow commands build deterministic tool calls only when
  the required handles are explicit or already present in workflow context.
  """

  @behaviour Ourocode.Runtime.Adapter

  alias Ourocode.TaskRequest

  @seed_tool "ouroboros_generate_seed"
  @run_tool "ouroboros_start_execute_seed"
  @auto_tool "ouroboros_start_auto"
  @ralph_tool "ouroboros_ralph"
  @evolve_step_tool "ouroboros_evolve_step"
  @lineage_status_tool "ouroboros_lineage_status"
  @evolve_rewind_tool "ouroboros_evolve_rewind"
  @status_tool "ouroboros_session_status"
  @evaluate_tool "ouroboros_evaluate"
  @qa_tool "ouroboros_qa"
  @lateral_tool "ouroboros_lateral_think"
  @brownfield_tool "ouroboros_brownfield"
  @default_method "tools/call"
  @client_gates ["seed_ready_acceptance_guard", "restate_goal_approved"]

  @type invocation :: %{
          required(:type) => :ouroboros_workflow_invocation,
          required(:status) => :ready | :invoked,
          required(:task_request_id) => String.t(),
          required(:adapter_route) =>
            :auto
            | :seed
            | :run
            | :ralph
            | :evolve
            | :status
            | :evaluate
            | :qa
            | :lateral
            | :brownfield,
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
  @spec build_request_payload(
          TaskRequest.t(),
          map(),
          :auto
          | :seed
          | :run
          | :ralph
          | :evolve
          | :status
          | :evaluate
          | :qa
          | :lateral
          | :brownfield
        ) ::
          {:ok, map()} | {:error, term()}
  def build_request_payload(%TaskRequest{} = task_request, context, :auto) do
    with {:ok, arguments} <- auto_arguments(task_request, context) do
      {:ok, payload(task_request, context, @auto_tool, arguments)}
    end
  end

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

  def build_request_payload(%TaskRequest{} = task_request, context, :ralph) do
    with {:ok, arguments} <- ralph_arguments(task_request, context) do
      {:ok, payload(task_request, context, @ralph_tool, arguments)}
    end
  end

  def build_request_payload(%TaskRequest{} = task_request, context, :evolve) do
    with {:ok, tool, arguments} <- evolve_tool_and_arguments(task_request, context) do
      {:ok, payload(task_request, context, tool, arguments)}
    end
  end

  def build_request_payload(%TaskRequest{} = task_request, context, :status) do
    with {:ok, session_id} <- execution_session_id(task_request, context) do
      {:ok, payload(task_request, context, @status_tool, %{"session_id" => session_id})}
    end
  end

  def build_request_payload(%TaskRequest{} = task_request, context, :evaluate) do
    with {:ok, session_id} <- execution_session_id(task_request, context),
         {:ok, artifact} <- evaluation_artifact(task_request, context) do
      arguments =
        %{
          "session_id" => session_id,
          "artifact" => artifact,
          "artifact_type" => explicit_artifact_type(task_request.task_input) || "code"
        }
        |> maybe_put("seed_content", seed_content(context))
        |> maybe_put_boolean(
          "trigger_consensus",
          flag_present?(workflow_tokens(task_request.task_input), "--consensus")
        )

      {:ok, payload(task_request, context, @evaluate_tool, arguments)}
    end
  end

  def build_request_payload(%TaskRequest{} = task_request, context, :qa) do
    with {:ok, arguments} <- qa_arguments(task_request, context) do
      {:ok, payload(task_request, context, @qa_tool, arguments)}
    end
  end

  def build_request_payload(%TaskRequest{} = task_request, context, :lateral) do
    with {:ok, arguments} <- lateral_arguments(task_request, context) do
      {:ok, payload(task_request, context, @lateral_tool, arguments)}
    end
  end

  def build_request_payload(%TaskRequest{} = task_request, context, :brownfield) do
    arguments = brownfield_arguments(task_request, context)
    {:ok, payload(task_request, context, @brownfield_tool, arguments)}
  end

  def build_request_payload(_task_request, _context, adapter_route),
    do: {:error, {:unsupported_ouroboros_workflow_action, adapter_route}}

  defp adapter_route(%TaskRequest{routing_decision: %{adapter_route: route}}, _context)
       when route in [
              :auto,
              :seed,
              :run,
              :ralph,
              :evolve,
              :status,
              :evaluate,
              :qa,
              :lateral,
              :brownfield
            ],
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

  defp auto_arguments(%TaskRequest{task_input: text}, context) do
    args = auto_tokens(text)

    cond do
      resume = flag_value(args, "--resume") ->
        if flag_value(args, "--pipeline-timeout-seconds") do
          {:error, :auto_resume_rejects_pipeline_timeout_seconds}
        else
          {:ok,
           %{"resume" => resume, "cwd" => Map.get(context, :cwd) || File.cwd!()}
           |> maybe_put_boolean("complete_product", flag_present?(args, "--complete-product"))
           |> maybe_put_boolean("skip_run", flag_present?(args, "--skip-run"))}
        end

      goal = auto_goal(args) ->
        {:ok,
         %{"goal" => goal, "cwd" => Map.get(context, :cwd) || File.cwd!()}
         |> maybe_put_boolean("complete_product", flag_present?(args, "--complete-product"))
         |> maybe_put_boolean("skip_run", flag_present?(args, "--skip-run"))
         |> maybe_put_integer("max_interview_rounds", flag_value(args, "--max-interview-rounds"))
         |> maybe_put_integer("max_repair_rounds", flag_value(args, "--max-repair-rounds"))
         |> maybe_put_number(
           "pipeline_timeout_seconds",
           flag_value(args, "--pipeline-timeout-seconds")
         )}

      true ->
        {:error, :missing_auto_goal}
    end
  end

  defp auto_tokens(text) when is_binary(text) do
    text |> workflow_tokens() |> drop_action_command("auto")
  end

  defp workflow_tokens(text) when is_binary(text), do: String.split(text, ~r/\s+/u, trim: true)

  defp drop_action_command(["ooo", action | rest], action), do: rest
  defp drop_action_command(["ouroboros", action | rest], action), do: rest

  defp drop_action_command([shortcut | rest], action) do
    if shortcut == "ouroboros:" <> action, do: rest, else: [shortcut | rest]
  end

  defp drop_action_command(tokens, _action), do: tokens

  defp auto_goal(tokens) do
    tokens
    |> strip_flag_pairs()
    |> Enum.reject(&known_auto_boolean_flag?/1)
    |> Enum.join(" ")
    |> String.trim()
    |> trim_wrapping_quotes()
    |> case do
      "" -> nil
      goal -> goal
    end
  end

  defp strip_flag_pairs([]), do: []

  defp strip_flag_pairs([flag, _value | rest])
       when flag in [
              "--resume",
              "--max-interview-rounds",
              "--max-repair-rounds",
              "--pipeline-timeout-seconds"
            ],
       do: strip_flag_pairs(rest)

  defp strip_flag_pairs([token | rest]), do: [token | strip_flag_pairs(rest)]

  defp flag_present?(tokens, flag), do: flag in tokens

  defp flag_value(tokens, flag) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^flag, value] -> value
      _other -> nil
    end)
  end

  defp known_auto_boolean_flag?(token), do: token in ["--complete-product", "--skip-run"]

  defp trim_wrapping_quotes(text) do
    text
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp maybe_put_integer(map, _key, nil), do: map

  defp maybe_put_integer(map, key, value) do
    case Integer.parse(value) do
      {integer, ""} -> Map.put(map, key, integer)
      _other -> map
    end
  end

  defp maybe_put_number(map, _key, nil), do: map

  defp maybe_put_number(map, key, value) do
    case Float.parse(value) do
      {number, ""} -> Map.put(map, key, number)
      _other -> map
    end
  end

  defp maybe_put_boolean(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_boolean(map, _key, _value), do: map

  defp put_boolean(map, key, value) when is_boolean(value), do: Map.put(map, key, value)

  defp ralph_arguments(%TaskRequest{task_input: text, id: id}, context) do
    tokens = drop_action_command(workflow_tokens(text), "ralph")

    lineage_id = flag_value(tokens, "--lineage-id") || explicit_lineage_id(text)
    seed = seed_content(context)

    cond do
      lineage_id ->
        {:ok,
         %{
           "lineage_id" => lineage_id,
           "project_dir" => Map.get(context, :cwd) || File.cwd!()
         }
         |> maybe_put("seed_content", seed)
         |> put_boolean("execute", !flag_present?(tokens, "--no-execute"))
         |> put_boolean("parallel", !flag_present?(tokens, "--serial"))
         |> maybe_put_boolean("skip_qa", explicit_skip_qa(text))
         |> maybe_put_integer("max_generations", flag_value(tokens, "--max-generations"))}

      seed ->
        {:ok,
         %{
           "lineage_id" => generated_lineage_id("ralph", id),
           "seed_content" => seed,
           "project_dir" => Map.get(context, :cwd) || File.cwd!()
         }
         |> maybe_put_integer("max_generations", flag_value(tokens, "--max-generations"))}

      true ->
        {:error, :missing_ralph_lineage_or_seed}
    end
  end

  defp evolve_tool_and_arguments(%TaskRequest{task_input: text, id: id}, context) do
    tokens = drop_action_command(workflow_tokens(text), "evolve")
    rewind = rewind_args(tokens)

    cond do
      lineage_id = flag_value(tokens, "--status") ->
        {:ok, @lineage_status_tool, %{"lineage_id" => lineage_id}}

      rewind ->
        {lineage_id, generation} = rewind

        {:ok, @evolve_rewind_tool, %{"lineage_id" => lineage_id, "to_generation" => generation}}

      lineage_id = flag_value(tokens, "--lineage-id") || explicit_lineage_id(text) ->
        {:ok, @evolve_step_tool,
         %{
           "lineage_id" => lineage_id,
           "project_dir" => Map.get(context, :cwd) || File.cwd!()
         }
         |> put_boolean("execute", !flag_present?(tokens, "--no-execute"))
         |> maybe_put_boolean("skip_qa", explicit_skip_qa(text))}

      seed = seed_content(context) ->
        {:ok, @evolve_step_tool,
         %{
           "lineage_id" => generated_lineage_id("evolve", id),
           "seed_content" => seed,
           "project_dir" => Map.get(context, :cwd) || File.cwd!()
         }
         |> put_boolean("execute", !flag_present?(tokens, "--no-execute"))
         |> maybe_put_boolean("skip_qa", explicit_skip_qa(text))}

      true ->
        {:error, :missing_evolve_lineage_or_seed}
    end
  end

  defp rewind_args(tokens) do
    case Enum.drop_while(tokens, &(&1 != "--rewind")) do
      ["--rewind", lineage_id, generation | _rest] ->
        case Integer.parse(generation) do
          {number, ""} -> {lineage_id, number}
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp qa_arguments(%TaskRequest{task_input: text}, context) do
    tokens = drop_action_command(workflow_tokens(text), "qa")

    with {:ok, artifact} <- qa_artifact(text, tokens, context),
         {:ok, quality_bar} <- quality_bar(text, context) do
      {:ok,
       %{
         "artifact" => artifact,
         "quality_bar" => quality_bar,
         "artifact_type" => explicit_artifact_type(text) || qa_artifact_type(tokens)
       }
       |> maybe_put("seed_content", seed_content(context))
       |> maybe_put_number("pass_threshold", flag_value(tokens, "--pass-threshold"))
       |> maybe_put("qa_session_id", explicit_qa_session_id(text))}
    end
  end

  defp qa_artifact(text, tokens, context) do
    cond do
      artifact = Map.get(context, :latest_evaluation_artifact) ->
        {:ok, artifact}

      path = explicit_artifact_path(text) || first_existing_path(tokens, context) ->
        read_text_file(path, Map.get(context, :cwd) || File.cwd!())

      inline = inline_remainder(tokens, known_qa_boolean_flags()) ->
        {:ok, inline}

      true ->
        {:error, :missing_qa_artifact}
    end
  end

  defp quality_bar(text, context) do
    cond do
      bar = explicit_quality_bar(text) ->
        {:ok, bar}

      seed = seed_content(context) ->
        {:ok, "Pass when the artifact satisfies this Seed specification:\n" <> seed}

      true ->
        {:error, :missing_quality_bar}
    end
  end

  defp lateral_arguments(%TaskRequest{task_input: text}, context) do
    tokens = drop_action_command(workflow_tokens(text), "lateral")
    tokens = drop_action_command(tokens, "unstuck")

    with {:ok, problem_context, current_approach} <- lateral_context(text, tokens, context),
         {:ok, persona_args} <- lateral_persona_args(tokens) do
      {:ok,
       %{
         "problem_context" => problem_context,
         "current_approach" => current_approach
       }
       |> Map.merge(persona_args)
       |> maybe_put("failed_attempts", Map.get(context, :latest_failed_attempts))}
    end
  end

  defp lateral_context(_text, tokens, context) do
    problem_context = Map.get(context, :latest_problem_context) || inline_remainder(tokens, [])
    current_approach = Map.get(context, :latest_current_approach)

    cond do
      is_binary(problem_context) and problem_context != "" and
        is_binary(current_approach) and current_approach != "" ->
        {:ok, problem_context, current_approach}

      is_binary(problem_context) and problem_context != "" ->
        {:ok, problem_context, "none yet - first attempt"}

      true ->
        {:error, :missing_lateral_context}
    end
  end

  defp lateral_persona_args(tokens) do
    case tokens do
      [] ->
        {:ok, %{"personas" => valid_lateral_personas()}}

      ["@all" | _rest] ->
        {:ok, %{"personas" => valid_lateral_personas()}}

      ["debate" | rest] ->
        {:ok, %{"personas" => lateral_personas(rest)}}

      [persona | _rest]
      when persona in ["hacker", "researcher", "simplifier", "architect", "contrarian"] ->
        {:ok, %{"persona" => persona}}

      [unknown | _rest] ->
        if likely_problem_text?(unknown) do
          {:ok, %{"personas" => valid_lateral_personas()}}
        else
          {:error, {:invalid_lateral_personas, [unknown]}}
        end
    end
  end

  defp brownfield_arguments(%TaskRequest{task_input: text}, context) do
    tokens = drop_action_command(workflow_tokens(text), "brownfield")
    action = brownfield_action(tokens)

    %{"action" => action}
    |> maybe_put("indices", brownfield_indices(tokens))
    |> maybe_put("scan_root", flag_value(tokens, "--scan-root") || explicit_scan_root(text))
    |> maybe_put("path", brownfield_path(tokens, context))
    |> maybe_put_boolean("default_only", action == "defaults")
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

  defp execution_session_id(%TaskRequest{task_input: text}, context) do
    case explicit_session_id(text) || Map.get(context, :latest_execution_id) ||
           Map.get(context, :latest_workflow_session_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _none -> {:error, :missing_execution_session_id}
    end
  end

  defp explicit_lineage_id(text) when is_binary(text) do
    case Regex.run(~r/(?:lineage[_\s-]?id=|lineage\s+)([A-Za-z0-9_.-]+)/i, text) do
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

  defp evaluation_artifact(%TaskRequest{task_input: text}, context) do
    cond do
      artifact = Map.get(context, :latest_evaluation_artifact) ->
        {:ok, artifact}

      path = explicit_artifact_path(text) ->
        read_text_file(path, Map.get(context, :cwd) || File.cwd!())

      true ->
        {:error, :missing_evaluation_artifact}
    end
  end

  defp explicit_artifact_path(text) when is_binary(text) do
    case Regex.run(~r/(?:artifact[_\s-]?path=|artifact\s+|file\s+)([^\s]+)/i, text) do
      [_, path] -> path
      _none -> nil
    end
  end

  defp explicit_artifact_type(text) when is_binary(text) do
    case Regex.run(~r/\b(?:artifact[_\s-]?type=|type\s+)(code|docs|config|text)\b/i, text) do
      [_, type] -> String.downcase(type)
      _none -> nil
    end
  end

  defp explicit_quality_bar(text) when is_binary(text) do
    case Regex.run(~r/(?:quality[_\s-]?bar=|bar\s+)(.+)$/i, text) do
      [_, bar] -> String.trim(bar)
      _none -> nil
    end
  end

  defp explicit_qa_session_id(text) when is_binary(text) do
    case Regex.run(~r/(?:qa[_\s-]?session[_\s-]?id=|qa[_\s-]?session\s+)([A-Za-z0-9_.-]+)/i, text) do
      [_, id] -> id
      _none -> nil
    end
  end

  defp explicit_scan_root(text) when is_binary(text) do
    case Regex.run(~r/(?:scan[_\s-]?root=|root\s+)([^\s]+)/i, text) do
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

  defp first_existing_path(tokens, context) do
    cwd = Map.get(context, :cwd) || File.cwd!()

    Enum.find(tokens, fn token ->
      path = if Path.type(token) == :absolute, do: token, else: Path.expand(token, cwd)
      File.regular?(path)
    end)
  end

  defp inline_remainder(tokens, known_boolean_flags) do
    tokens
    |> strip_common_flag_pairs()
    |> Enum.reject(&(&1 in known_boolean_flags))
    |> Enum.reject(&String.starts_with?(&1, "--"))
    |> Enum.reject(&(&1 in valid_lateral_personas()))
    |> Enum.reject(&(&1 in ["debate", "@all"]))
    |> Enum.join(" ")
    |> String.trim()
    |> trim_wrapping_quotes()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp strip_common_flag_pairs([]), do: []

  defp strip_common_flag_pairs([flag, _value | rest])
       when flag in [
              "--pass-threshold",
              "--quality-bar",
              "--artifact-type",
              "--scan-root",
              "--qa-session-id"
            ],
       do: strip_common_flag_pairs(rest)

  defp strip_common_flag_pairs([token | rest]), do: [token | strip_common_flag_pairs(rest)]

  defp known_qa_boolean_flags, do: []

  defp qa_artifact_type(tokens) do
    cond do
      Enum.any?(tokens, &String.ends_with?(&1, [".md", ".markdown", ".txt"])) -> "document"
      Enum.any?(tokens, &String.ends_with?(&1, [".json"])) -> "api_response"
      Enum.any?(tokens, &String.ends_with?(&1, [".ex", ".exs", ".js", ".ts", ".py"])) -> "code"
      true -> "custom"
    end
  end

  defp valid_lateral_personas do
    ["hacker", "researcher", "simplifier", "architect", "contrarian"]
  end

  defp lateral_personas([]), do: valid_lateral_personas()

  defp lateral_personas(args) do
    personas = Enum.filter(args, &(&1 in valid_lateral_personas()))
    if personas == [], do: valid_lateral_personas(), else: personas
  end

  defp likely_problem_text?(token) when is_binary(token) do
    token not in ["hacker", "researcher", "simplifier", "architect", "contrarian"]
  end

  defp brownfield_action(["scan" | _tokens]), do: "scan"
  defp brownfield_action(["defaults" | _tokens]), do: "query"
  defp brownfield_action(["default" | _tokens]), do: "query"
  defp brownfield_action(["set" | _tokens]), do: "set_default"
  defp brownfield_action(["detect" | _tokens]), do: "detect"
  defp brownfield_action(_tokens), do: "scan"

  defp brownfield_indices(["set", indices | _tokens]), do: indices
  defp brownfield_indices(_tokens), do: nil

  defp brownfield_path(["detect", path | _tokens], _context), do: path
  defp brownfield_path(["detect"], context), do: Map.get(context, :cwd)
  defp brownfield_path(_tokens, _context), do: nil

  defp seed_content(context) do
    cond do
      seed = Map.get(context, :latest_seed_content) ->
        seed

      path = Map.get(context, :latest_seed_path) ->
        case read_text_file(path, Map.get(context, :cwd) || File.cwd!()) do
          {:ok, content} -> content
          {:error, _reason} -> nil
        end

      true ->
        nil
    end
  end

  defp read_text_file(path, cwd) when is_binary(path) and is_binary(cwd) do
    expanded =
      if Path.type(path) == :absolute,
        do: path,
        else: Path.expand(path, cwd)

    case File.read(expanded) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_failed, expanded, reason}}
    end
  end

  defp generated_lineage_id(prefix, id) do
    slug =
      id
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_.-]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "task"
        value -> value
      end

    prefix <> "-" <> slug
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
