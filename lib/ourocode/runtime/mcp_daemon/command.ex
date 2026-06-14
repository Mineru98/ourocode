defmodule Ourocode.Runtime.McpDaemon.Command do
  @moduledoc """
  Builds the external command used to launch the Ouroboros MCP daemon.
  """

  @spec build(String.t(), :inet.port_number(), term(), (String.t() -> String.t() | nil)) ::
          {String.t(), [String.t()]} | :none
  def build(host, port, llm_backend, executable_finder \\ &System.find_executable/1)
      when is_binary(host) and is_integer(port) and is_function(executable_finder, 1) do
    serve_args =
      [
        "mcp",
        "serve",
        "--transport",
        "streamable-http",
        "--host",
        host,
        "--port",
        Integer.to_string(port)
      ]
      |> backend_args(llm_backend)

    # Prefer `uvx` because it pins the `[mcp,claude]` extras on every run.
    # Bare `ouroboros` remains the fallback when uvx is unavailable.
    cond do
      exe = executable_finder.("uvx") ->
        {exe, ["--from", "ouroboros-ai[mcp,claude]", "ouroboros"] ++ serve_args}

      exe = executable_finder.("ouroboros") ->
        {exe, serve_args}

      true ->
        :none
    end
  end

  # Ourocode is the parent TUI, not the OpenCode bridge plugin. Keep the MCP
  # server on a non-plugin runtime unless Codex execution is explicitly chosen;
  # otherwise a user config with opencode_mode=plugin returns status envelopes
  # instead of inline interview questions.
  defp backend_args(args, nil), do: args ++ ["--runtime", "claude"]
  defp backend_args(args, ""), do: args ++ ["--runtime", "claude"]

  defp backend_args(args, "codex") do
    args ++ ["--runtime", "codex", "--llm-backend", "codex"]
  end

  defp backend_args(args, "opencode") do
    args ++ ["--runtime", "claude", "--llm-backend", "opencode"]
  end

  defp backend_args(args, "claude_code") do
    args ++ ["--runtime", "claude", "--llm-backend", "claude_code"]
  end

  defp backend_args(args, "gemini") do
    args ++ ["--runtime", "claude", "--llm-backend", "gemini"]
  end

  defp backend_args(args, backend),
    do: args ++ ["--runtime", "claude", "--llm-backend", to_string(backend)]
end
