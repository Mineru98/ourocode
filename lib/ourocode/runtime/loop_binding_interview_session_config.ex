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
      payload: Keyword.fetch!(opts, :initial_payload),
      round: 1,
      max_rounds: Keyword.get(opts, :max_rounds, Keyword.fetch!(defaults, :max_rounds)),
      router_decision_timeout_ms:
        Keyword.get(
          opts,
          :router_decision_timeout_ms,
          Keyword.fetch!(defaults, :router_decision_timeout_ms)
        ),
      streak: 0,
      session_id: nil
    }
  end
end
