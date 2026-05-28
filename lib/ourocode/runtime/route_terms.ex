defmodule Ourocode.Runtime.RouteTerms do
  @moduledoc """
  Token and keyword matching helpers for runtime route classification.
  """

  @spec normalize(String.t()) :: String.t()
  def normalize(input) when is_binary(input) do
    input
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  @spec tokens(String.t()) :: [String.t()]
  def tokens(task_input) when is_binary(task_input) do
    task_input
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.:\-\/]+/u, " ")
    |> String.split(" ", trim: true)
  end

  @spec mcp_flow?([String.t()]) :: boolean()
  def mcp_flow?(tokens) when is_list(tokens) do
    Enum.any?(tokens, &(&1 in ["mcp", "tools/call", "tools.call", "json-rpc", "jsonrpc"])) or
      Enum.any?(tokens, &String.starts_with?(&1, "mcp:"))
  end

  @spec explicit_mcp_shortcut?([String.t()]) :: boolean()
  def explicit_mcp_shortcut?([first | _tokens]) do
    first in ["mcp", "tools/call", "tools.call"]
  end

  def explicit_mcp_shortcut?(_tokens), do: false

  @spec explicit_diagnostics_shortcut?([String.t()]) :: boolean()
  def explicit_diagnostics_shortcut?([first | _tokens]) do
    first in ["diag", "diagnostics", "diagnostics:runtime", "diagnostics:streams"]
  end

  def explicit_diagnostics_shortcut?(_tokens), do: false

  @spec explicit_test_shortcut?([String.t()]) :: boolean()
  def explicit_test_shortcut?([first | _tokens]) do
    first in ["test:transport", "test:transports", "tests:transport", "tests:transports"]
  end

  def explicit_test_shortcut?(_tokens), do: false

  @spec ouroboros_workflow?([String.t()]) :: boolean()
  def ouroboros_workflow?(tokens) when is_list(tokens) do
    Enum.any?(tokens, &(&1 in ["interview", "seed", "evolve", "ralph", "workflow"])) or
      Enum.any?(tokens, &String.starts_with?(&1, "ouroboros:"))
  end

  @spec ouroboros_adapter_route([String.t()]) ::
          :interview | :seed | :evolve | :ralph | :run | :workflow
  def ouroboros_adapter_route(tokens) when is_list(tokens) do
    cond do
      Enum.any?(tokens, &(&1 in ["interview", "pm", "ouroboros:interview", "ouroboros:pm"])) ->
        :interview

      Enum.any?(tokens, &(&1 in ["seed", "ouroboros:seed"])) ->
        :seed

      Enum.any?(tokens, &(&1 in ["evolve", "ouroboros:evolve"])) ->
        :evolve

      Enum.any?(tokens, &(&1 in ["ralph", "ouroboros:ralph"])) ->
        :ralph

      explicit_ouroboros_run?(tokens) ->
        :run

      Enum.any?(tokens, &(&1 in ["workflow", "ouroboros:workflow"])) ->
        :workflow

      true ->
        :workflow
    end
  end

  @spec transport_from_tokens([String.t()]) :: :auto | :stdio | :streamable_http | :sse
  def transport_from_tokens(tokens) when is_list(tokens) do
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

  defp explicit_ouroboros_run?(["ooo", action | _tokens]) when action in ["run", "execute"],
    do: true

  defp explicit_ouroboros_run?(["ouroboros", action | _tokens])
       when action in ["run", "execute"],
       do: true

  defp explicit_ouroboros_run?(tokens),
    do: Enum.any?(tokens, &(&1 in ["ouroboros:run", "ouroboros:execute"]))
end
