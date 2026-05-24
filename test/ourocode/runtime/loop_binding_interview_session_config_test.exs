defmodule Ourocode.Runtime.LoopBindingInterviewSessionConfigTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.LoopBindingInterviewSessionConfig

  test "build creates the initial interview loop state from opts and defaults" do
    callbacks = %{enqueue: fn _agent, _event -> :ok end}
    parent_call_fun = fn payload -> {:ok, payload} end

    state =
      LoopBindingInterviewSessionConfig.build(
        [
          parent_call_id: "parent-1",
          initial_payload: %{"goal" => "ship"},
          parent_call_fun: parent_call_fun,
          model: "gpt-5",
          project_dir: "/tmp/project",
          max_rounds: 3,
          router_decision_timeout_ms: 250
        ],
        callbacks: callbacks,
        max_rounds: 9,
        router_decision_timeout_ms: 1_000
      )

    assert state == %{
             callbacks: callbacks,
             pcf: parent_call_fun,
             model: "gpt-5",
             project_dir: "/tmp/project",
             parent_call_id: "parent-1",
             payload: %{"goal" => "ship"},
             round: 1,
             max_rounds: 3,
             router_decision_timeout_ms: 250,
             streak: 0,
             session_id: nil
           }
  end

  test "build falls back to defaults for optional loop limits" do
    state =
      LoopBindingInterviewSessionConfig.build(
        [
          parent_call_id: "parent-2",
          initial_payload: %{},
          parent_call_fun: fn payload -> {:ok, payload} end,
          model: "gpt-5"
        ],
        callbacks: %{},
        max_rounds: 7,
        router_decision_timeout_ms: 900
      )

    assert state.max_rounds == 7
    assert state.router_decision_timeout_ms == 900
    assert is_binary(state.project_dir)
  end
end
