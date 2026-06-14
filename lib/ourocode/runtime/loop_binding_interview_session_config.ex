defmodule Ourocode.Runtime.LoopBindingInterviewSessionConfig do
  @moduledoc """
  Builds the initial state for loop-binding interview sessions.
  """

  @spec build(keyword(), keyword()) :: map()
  def build(opts, defaults) when is_list(opts) and is_list(defaults) do
    project_dir = Keyword.get(opts, :project_dir) || File.cwd!()

    %{
      callbacks: Keyword.fetch!(defaults, :callbacks),
      pcf: Keyword.fetch!(opts, :parent_call_fun),
      model: Keyword.fetch!(opts, :model),
      project_dir: project_dir,
      parent_call_id: Keyword.fetch!(opts, :parent_call_id),
      workflow_run_id:
        Keyword.get(opts, :workflow_run_id) ||
          "workflow-run:" <> Keyword.fetch!(opts, :parent_call_id),
      payload: Keyword.fetch!(opts, :initial_payload),
      round: 1,
      max_rounds: Keyword.get(opts, :max_rounds, Keyword.fetch!(defaults, :max_rounds)),
      router_decision_timeout_ms:
        Keyword.get(
          opts,
          :router_decision_timeout_ms,
          Keyword.fetch!(defaults, :router_decision_timeout_ms)
        ),
      initial_context: initial_context(Keyword.fetch!(opts, :initial_payload)),
      mcp_tool: mcp_tool(Keyword.fetch!(opts, :initial_payload)),
      max_status_polls:
        Keyword.get(opts, :max_status_polls, Keyword.get(defaults, :max_status_polls, 8)),
      status_poll_delay_ms:
        Keyword.get(
          opts,
          :status_poll_delay_ms,
          Keyword.get(defaults, :status_poll_delay_ms, 1_000)
        ),
      status_poll_count: 0,
      user_routed?: user_routed?(Keyword.fetch!(opts, :initial_payload)),
      streak: 0,
      session_id: nil
    }
  end

  defp user_routed?(payload) when is_map(payload) do
    payload
    |> initial_context()
    |> String.trim()
    |> String.downcase()
    |> String.starts_with?("ooo pm")
  end

  defp initial_context(payload) do
    Ourocode.Runtime.LoopBindingInterviewText.initial_context_from_payload(payload)
  end

  # Followup/resume rounds must keep calling the tool that opened the session
  # (`ouroboros_interview` or `ouroboros_pm_interview`), so the session state
  # pins the tool name from the initial tools/call payload.
  defp mcp_tool(payload) when is_map(payload) do
    case get_in(payload, ["params", "name"]) do
      tool when is_binary(tool) and tool != "" -> tool
      _none -> nil
    end
  end

  defp mcp_tool(_payload), do: nil
end
