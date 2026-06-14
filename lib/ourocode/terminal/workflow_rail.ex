defmodule Ourocode.Terminal.WorkflowRail do
  @moduledoc false

  @stages [
    {:interview, "socratic"},
    {:plan, "plan"},
    {:execute, "execute"},
    {:verify, "verify"},
    {:evidence, "evidence"}
  ]

  @spec rows([{String.t(), [String.t()]}], [String.t()], [String.t()], map()) :: [String.t()]
  def rows(sections, reasoning, mcp_activity, workflow \\ %{}) do
    body = Ourocode.Terminal.FrameSections.body(sections, "Parent/Child Sessions")
    run = latest_run(workflow)

    @stages
    |> Enum.map(fn {stage, label} ->
      stage_row(label, stage_status(stage, body, reasoning, mcp_activity, run))
    end)
  end

  defp stage_row(label, status) do
    "● " <> label <> " " <> status
  end

  defp stage_status(stage, _body, _reasoning, _mcp_activity, %{adapter_route: adapter} = run)
       when adapter == stage or (stage == :plan and adapter == :seed) or
              (stage == :execute and adapter in [:run, :evolve, :ralph, :workflow]) do
    run_status(run)
  end

  defp stage_status(:evidence, _body, _reasoning, _mcp_activity, %{evidence: [_first | _rest]}) do
    "recorded"
  end

  defp stage_status(:interview, _body, reasoning, _mcp_activity, _run) do
    cond do
      reasoning != [] -> "live"
      true -> "ready"
    end
  end

  defp stage_status(:plan, body, reasoning, _mcp_activity, _run) do
    cond do
      body_text?(body, ~r/plan|seed|interview/i) -> "active"
      reasoning != [] -> "warming"
      true -> "ready"
    end
  end

  defp stage_status(:execute, body, _reasoning, mcp_activity, _run) do
    cond do
      body_text?(body, ~r/failed|error/i) -> "attention"
      body_text?(body, ~r/child |ledger=|toolcall|tools\/call/i) -> "live"
      mcp_activity != [] -> "live"
      true -> "ready"
    end
  end

  defp stage_status(:verify, body, _reasoning, _mcp_activity, _run) do
    cond do
      body_text?(body, ~r/qa|verify|evaluate|test/i) -> "active"
      body_text?(body, ~r/completed|success|passed/i) -> "evidence"
      true -> "ready"
    end
  end

  defp stage_status(:evidence, body, _reasoning, _mcp_activity, _run) do
    cond do
      body_text?(body, ~r/evidence|passed|qa passed|receipt/i) -> "recorded"
      true -> "ready"
    end
  end

  defp body_text?(body, pattern) do
    Enum.any?(body, &Regex.match?(pattern, &1))
  end

  defp latest_run(%{latest_run_id: id, runs: runs}) when is_binary(id) and is_map(runs),
    do: Map.get(runs, id)

  defp latest_run(%{"latest_run_id" => id, "runs" => runs}) when is_binary(id) and is_map(runs),
    do: Map.get(runs, id)

  defp latest_run(_workflow), do: nil

  defp run_status(%{status: :dispatching}), do: "dispatching"
  defp run_status(%{status: :waiting}), do: "waiting"
  defp run_status(%{status: :retrying}), do: "retrying"
  defp run_status(%{status: :needs_user}), do: "needs user"
  defp run_status(%{status: :completed}), do: "done"
  defp run_status(%{status: :failed}), do: "failed"
  defp run_status(%{status: :cancelled}), do: "cancelled"
  defp run_status(%{status: status}) when is_binary(status), do: status
  defp run_status(_run), do: "active"
end
