defmodule Ourocode.Runtime.OuroborosDirectInvocation do
  @moduledoc """
  Builds deterministic direct actions for Ouroboros skills that are not MCP calls.

  Some control skills intentionally use the local Ouroboros CLI or a guided
  multi-step surface instead of `tools/call`. This adapter keeps those routes
  out of the default natural-language runtime and out of the MCP relay.
  """

  @behaviour Ourocode.Runtime.Adapter

  alias Ourocode.TaskRequest

  @direct_routes [
    :cancel,
    :resume_session,
    :update,
    :setup,
    :publish,
    :welcome,
    :tutorial,
    :help
  ]

  @type direct_action :: %{
          required(:type) => :ouroboros_direct_invocation,
          required(:status) => :ready | :invoked,
          required(:task_request_id) => String.t(),
          required(:adapter_route) => atom(),
          required(:mode) => :command | :guided_steps,
          optional(:command) => String.t(),
          optional(:args) => [String.t()],
          optional(:steps) => [map()],
          optional(:result) => term()
        }

  @impl true
  @spec execute(TaskRequest.t(), map()) :: {:ok, direct_action()} | {:error, term()}
  def execute(%TaskRequest{} = task_request, context) when is_map(context) do
    with {:ok, adapter_route} <- adapter_route(task_request),
         {:ok, action} <- build_action(task_request, context, adapter_route),
         {:ok, status, result} <- maybe_run(action, context) do
      {:ok,
       action
       |> Map.merge(%{
         type: :ouroboros_direct_invocation,
         status: status,
         task_request_id: to_string(task_request.id),
         adapter_route: adapter_route
       })
       |> maybe_put(:result, result)}
    end
  end

  def execute(_task_request, _context), do: {:error, :invalid_task_request}

  @doc false
  @spec build_action(TaskRequest.t(), map(), atom()) :: {:ok, map()} | {:error, term()}
  def build_action(%TaskRequest{} = task_request, context, :cancel) do
    {:ok,
     %{
       mode: :command,
       command: "ouroboros",
       args: ["cancel", "execution"] ++ cancel_args(task_request.task_input, context)
     }}
  end

  def build_action(%TaskRequest{} = task_request, _context, :resume_session) do
    {:ok,
     %{
       mode: :command,
       command: "ouroboros",
       args: ["resume"] ++ resume_args(task_request.task_input)
     }}
  end

  def build_action(%TaskRequest{} = task_request, _context, :setup) do
    {:ok,
     %{
       mode: :command,
       command: "ouroboros",
       args: ["setup"] ++ setup_args(task_request.task_input)
     }}
  end

  def build_action(%TaskRequest{} = task_request, context, :update) do
    {:ok,
     %{
       mode: :guided_steps,
       steps: [
         command_step("current_version", "ouroboros", ["--version"]),
         command_step("latest_version", "python3", [
           "-c",
           "import json, urllib.request; print(json.load(urllib.request.urlopen('https://pypi.org/pypi/ouroboros-ai/json', timeout=5))['info']['version'])"
         ]),
         command_step(
           "upgrade",
           installer_command(context),
           installer_args(task_request.task_input)
         )
       ]
     }}
  end

  def build_action(%TaskRequest{} = task_request, context, :publish) do
    seed_path = explicit_seed_path(task_request.task_input) || Map.get(context, :latest_seed_path)

    {:ok,
     %{
       mode: :guided_steps,
       steps:
         [
           command_step("check_gh", "gh", ["auth", "status"]),
           command_step("detect_repo", "gh", [
             "repo",
             "view",
             "--json",
             "nameWithOwner",
             "-q",
             ".nameWithOwner"
           ])
         ] ++ publish_seed_steps(seed_path)
     }}
  end

  def build_action(%TaskRequest{} = task_request, _context, :welcome) do
    {:ok,
     %{
       mode: :guided_steps,
       steps: [
         %{
           id: "welcome",
           kind: :interactive_surface,
           action:
             if(flag_present?(tokens(task_request.task_input), "--skip"),
               do: "skip",
               else: "show"
             )
         }
       ]
     }}
  end

  def build_action(_task_request, _context, :tutorial) do
    {:ok,
     %{
       mode: :guided_steps,
       steps: [
         %{id: "tutorial", kind: :interactive_surface, action: "start_hands_on_tutorial"}
       ]
     }}
  end

  def build_action(_task_request, _context, :help) do
    {:ok,
     %{
       mode: :guided_steps,
       steps: [
         %{id: "help", kind: :reference_surface, action: "show_ouroboros_command_reference"}
       ]
     }}
  end

  def build_action(_task_request, _context, adapter_route),
    do: {:error, {:unsupported_ouroboros_direct_action, adapter_route}}

  defp adapter_route(%TaskRequest{routing_decision: %{adapter_route: route}})
       when route in @direct_routes,
       do: {:ok, route}

  defp adapter_route(%TaskRequest{routing_decision: routing_decision}) do
    {:error, {:unsupported_ouroboros_direct_action, Map.get(routing_decision, :adapter_route)}}
  end

  defp cancel_args(text, context) do
    tokens = tokens(text)

    cond do
      "--all" in tokens or "all" in tokens ->
        ["--all"]

      id = explicit_execution_id(text) || Map.get(context, :latest_execution_id) ->
        [id] ++ reason_args(text)

      true ->
        []
    end
  end

  defp resume_args(text) do
    if "--all" in tokens(text), do: ["--all"], else: []
  end

  defp setup_args(text) do
    if "--uninstall" in tokens(text), do: ["--uninstall"], else: ["--runtime", "codex"]
  end

  defp reason_args(text) do
    case Regex.run(~r/(?:--reason|reason)\s+(.+)$/i, text) do
      [_, reason] -> ["--reason", String.trim(reason)]
      _none -> []
    end
  end

  defp publish_seed_steps(nil), do: [%{id: "select_seed", kind: :ask_user, action: "choose_seed"}]

  defp publish_seed_steps(seed_path) do
    [
      %{id: "read_seed", kind: :read_file, path: seed_path},
      %{id: "create_issues", kind: :guided_gh_issue_creation, seed_path: seed_path}
    ]
  end

  defp maybe_run(%{mode: :command, command: command, args: args}, context) do
    runner = Map.get(context, :external_command_runner)

    if is_function(runner, 3) do
      case runner.(command, args, cd: Map.get(context, :cwd) || File.cwd!()) do
        {:ok, result} -> {:ok, :invoked, result}
        {:error, :external_command_runner_not_configured} -> {:ok, :ready, nil}
        {:error, reason} -> {:error, reason}
        other -> {:ok, :invoked, other}
      end
    else
      {:ok, :ready, nil}
    end
  end

  defp maybe_run(_action, _context), do: {:ok, :ready, nil}

  defp command_step(id, command, args) do
    %{id: id, kind: :command, command: command, args: args}
  end

  defp installer_command(_context), do: "uv"

  defp installer_args(text) do
    if "--pre" in tokens(text) or "--prerelease" in tokens(text) do
      ["tool", "install", "--upgrade", "--prerelease=allow", "ouroboros-ai[claude]"]
    else
      ["tool", "install", "--upgrade", "ouroboros-ai[claude]"]
    end
  end

  defp explicit_execution_id(text) do
    case Regex.run(
           ~r/(?:execution[_\s-]?id=|exec[_\s-]?id=|execution\s+)([A-Za-z0-9_.-]+)/i,
           text
         ) do
      [_, id] -> id
      _none -> nil
    end
  end

  defp explicit_seed_path(text) do
    case Regex.run(~r/(?:seed[_\s-]?path=|(?:^|\s))([^\s]+\.(?:ya?ml|json))\b/i, text) do
      [_, path] -> path
      _none -> nil
    end
  end

  defp flag_present?(tokens, flag), do: flag in tokens

  defp tokens(text) when is_binary(text),
    do: String.split(String.downcase(text), ~r/\s+/u, trim: true)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
