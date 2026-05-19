defmodule Ourocode.Runtime.Router do
  @moduledoc """
  Internal task router for natural-language ourocode task input.

  The router returns both the machine routing decision used by dispatch and a
  compact user-visible result that can be shown in the prompt or dashboard
  before execution starts.
  """

  defstruct [
    :task_input,
    :execution_route,
    :runtime_source,
    :transport,
    :adapter_route,
    :advanced_shortcut?,
    :reason,
    :route_label,
    :runtime_label,
    :transport_label,
    :message,
    :routing_decision
  ]

  @type routing_decision :: %{
          required(:kind) => :runtime | :ouroboros_workflow | :mcp_flow,
          required(:execution_route) => :runtime | :ouroboros_workflow | :mcp_flow,
          required(:runtime_source) =>
            :auto | :codex | :opencode | :claude_code | :ouroboros | :mcp,
          required(:transport) => :auto | :stdio | :streamable_http | :sse,
          required(:requires_command_syntax?) => false,
          required(:advanced_shortcut?) => boolean(),
          required(:reason) => atom(),
          optional(:adapter_route) => atom()
        }

  @type t :: %__MODULE__{
          task_input: String.t(),
          execution_route: atom(),
          runtime_source: atom(),
          transport: atom(),
          adapter_route: atom() | nil,
          advanced_shortcut?: boolean(),
          reason: atom(),
          route_label: String.t(),
          runtime_label: String.t(),
          transport_label: String.t(),
          message: String.t(),
          routing_decision: routing_decision()
        }

  @doc """
  Routes task text and returns a user-visible routing result.
  """
  @spec route(String.t()) :: {:ok, t()} | {:error, String.t()}
  def route(input) when is_binary(input) do
    case normalize_task_input(input) do
      "" ->
        {:error, "task input cannot be blank"}

      task_input ->
        decision = routing_decision(task_input)
        {:ok, user_visible_result(task_input, decision)}
    end
  end

  def route(_input), do: {:error, "task input must be a string"}

  @doc """
  Returns only the machine routing decision used by runtime dispatch.
  """
  @spec routing_decision(String.t()) :: routing_decision()
  def routing_decision(task_input) when is_binary(task_input) do
    task_input
    |> normalize_task_input()
    |> classify_route()
    |> to_routing_decision()
  end

  defp user_visible_result(task_input, decision) do
    %__MODULE__{
      task_input: task_input,
      execution_route: decision.execution_route,
      runtime_source: decision.runtime_source,
      transport: decision.transport,
      adapter_route: Map.get(decision, :adapter_route),
      advanced_shortcut?: decision.advanced_shortcut?,
      reason: decision.reason,
      route_label: route_label(decision.execution_route, Map.get(decision, :adapter_route)),
      runtime_label: runtime_label(decision.runtime_source),
      transport_label: transport_label(decision.transport),
      message: routing_message(decision),
      routing_decision: decision
    }
  end

  defp to_routing_decision(route) do
    %{
      kind: route.kind,
      execution_route: route.kind,
      runtime_source: route.runtime_source,
      transport: route.transport,
      requires_command_syntax?: false,
      advanced_shortcut?: route.advanced_shortcut?,
      reason: route.reason,
      adapter_route: route.adapter_route
    }
    |> drop_nil_values()
  end

  defp classify_route(task_input) do
    tokens = route_tokens(task_input)
    first = List.first(tokens)
    ouroboros_adapter_route = ouroboros_adapter_route(tokens)

    cond do
      first in ["ooo", "ouroboros"] ->
        route(
          :ouroboros_workflow,
          :ouroboros,
          transport_from_tokens(tokens),
          true,
          :explicit_ouroboros_shortcut,
          ouroboros_adapter_route
        )

      explicit_diagnostics_shortcut?(tokens) ->
        route(
          :runtime,
          :auto,
          transport_from_tokens(tokens),
          true,
          :explicit_diagnostics_shortcut
        )

      explicit_test_shortcut?(tokens) ->
        route(
          :runtime,
          :auto,
          transport_from_tokens(tokens),
          true,
          :explicit_test_shortcut
        )

      first == "codex" ->
        route(:runtime, :codex, transport_from_tokens(tokens), true, :explicit_codex_shortcut)

      first == "opencode" ->
        route(:runtime, :opencode, transport_from_tokens(tokens), true, :explicit_opencode_shortcut)

      first in ["claude-code", "claude"] ->
        route(
          :runtime,
          :claude_code,
          transport_from_tokens(tokens),
          true,
          :explicit_claude_code_shortcut
        )

      mcp_flow?(tokens) ->
        route(
          :mcp_flow,
          :mcp,
          transport_from_tokens(tokens),
          explicit_mcp_shortcut?(tokens),
          :mcp_flow_terms
        )

      ouroboros_workflow?(tokens) ->
        route(
          :ouroboros_workflow,
          :ouroboros,
          transport_from_tokens(tokens),
          false,
          :ouroboros_workflow_terms,
          ouroboros_adapter_route
        )

      true ->
        route(
          :runtime,
          :auto,
          transport_from_tokens(tokens),
          false,
          :default_natural_language_runtime
        )
    end
  end

  defp route(kind, runtime_source, transport, advanced_shortcut?, reason, adapter_route \\ nil) do
    %{
      kind: kind,
      runtime_source: runtime_source,
      transport: transport,
      advanced_shortcut?: advanced_shortcut?,
      reason: reason,
      adapter_route: adapter_route
    }
  end

  defp normalize_task_input(input) do
    input
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp route_tokens(task_input) do
    task_input
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.:\-\/]+/u, " ")
    |> String.split(" ", trim: true)
  end

  defp mcp_flow?(tokens) do
    Enum.any?(tokens, &(&1 in ["mcp", "tools/call", "tools.call", "json-rpc", "jsonrpc"])) or
      Enum.any?(tokens, &String.starts_with?(&1, "mcp:"))
  end

  defp explicit_mcp_shortcut?([first | _tokens]) do
    first in ["mcp", "tools/call", "tools.call"]
  end

  defp explicit_mcp_shortcut?(_tokens), do: false

  defp explicit_diagnostics_shortcut?([first | _tokens]) do
    first in ["diag", "diagnostics", "diagnostics:runtime", "diagnostics:streams"]
  end

  defp explicit_diagnostics_shortcut?(_tokens), do: false

  defp explicit_test_shortcut?([first | _tokens]) do
    first in ["test:transport", "test:transports", "tests:transport", "tests:transports"]
  end

  defp explicit_test_shortcut?(_tokens), do: false

  defp ouroboros_workflow?(tokens) do
    Enum.any?(tokens, &(&1 in ["interview", "seed", "evolve", "ralph", "workflow"])) or
      Enum.any?(tokens, &String.starts_with?(&1, "ouroboros:"))
  end

  defp ouroboros_adapter_route(tokens) do
    cond do
      Enum.any?(tokens, &(&1 in ["interview", "ouroboros:interview"])) ->
        :interview

      Enum.any?(tokens, &(&1 in ["seed", "ouroboros:seed"])) ->
        :seed

      Enum.any?(tokens, &(&1 in ["evolve", "ouroboros:evolve"])) ->
        :evolve

      Enum.any?(tokens, &(&1 in ["ralph", "ouroboros:ralph"])) ->
        :ralph

      Enum.any?(tokens, &(&1 in ["workflow", "ouroboros:workflow"])) ->
        :workflow

      true ->
        :workflow
    end
  end

  defp transport_from_tokens(tokens) do
    cond do
      Enum.any?(tokens, &(&1 in ["stdio", "mcp:stdio"])) ->
        :stdio

      Enum.any?(tokens, &(&1 in ["sse", "mcp:sse"])) ->
        :sse

      Enum.any?(tokens, &(&1 in ["streamable-http", "streamable_http", "http", "mcp:http"])) ->
        :streamable_http

      true ->
        :auto
    end
  end

  defp route_label(:runtime, _adapter_route), do: "Runtime session"
  defp route_label(:mcp_flow, _adapter_route), do: "MCP flow"
  defp route_label(:ouroboros_workflow, nil), do: "Ouroboros workflow"

  defp route_label(:ouroboros_workflow, adapter_route) do
    "Ouroboros #{adapter_route_label(adapter_route)}"
  end

  defp adapter_route_label(:interview), do: "interview"
  defp adapter_route_label(:seed), do: "seed"
  defp adapter_route_label(:evolve), do: "evolve"
  defp adapter_route_label(:ralph), do: "Ralph"
  defp adapter_route_label(:workflow), do: "workflow"
  defp adapter_route_label(adapter_route), do: Atom.to_string(adapter_route)

  defp runtime_label(:auto), do: "Auto runtime"
  defp runtime_label(:codex), do: "Codex"
  defp runtime_label(:opencode), do: "OpenCode"
  defp runtime_label(:claude_code), do: "Claude Code"
  defp runtime_label(:ouroboros), do: "Ouroboros"
  defp runtime_label(:mcp), do: "MCP"

  defp transport_label(:auto), do: "Auto transport"
  defp transport_label(:stdio), do: "stdio"
  defp transport_label(:streamable_http), do: "streamable HTTP"
  defp transport_label(:sse), do: "SSE"

  defp routing_message(decision) do
    route = route_label(decision.execution_route, Map.get(decision, :adapter_route))
    runtime = runtime_label(decision.runtime_source)
    transport = transport_label(decision.transport)

    "#{route} via #{runtime} using #{transport}"
  end
end
