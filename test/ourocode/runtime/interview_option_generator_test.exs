defmodule Ourocode.Runtime.InterviewOptionGeneratorTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Runtime.InterviewOptionGenerator

  defp scripted_model(reply, status \\ :ready) do
    %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: status,
      run: fn _prompt, _opts, _on_chunk -> {:ok, reply} end
    }
  end

  test "generates options from plain option lines" do
    model =
      scripted_model("""
      - Existing bug path | Fix the observable failure first
      - Desired behavior | Define what should replace the failure
      """)

    assert {:ok, options} =
             InterviewOptionGenerator.generate("What failure should this bug fix?", model)

    assert Enum.map(options, & &1.label) == ["Existing bug path", "Desired behavior"]
  end

  test "generates options from ASK_USER-shaped model output" do
    model =
      scripted_model("""
      ASK_USER What should this clarify?
      - User-visible failure | Describe what users see today
      - Correct replacement | Describe the expected fixed behavior
      """)

    assert {:ok, options} =
             InterviewOptionGenerator.generate("What should this clarify?", model)

    assert Enum.map(options, & &1.label) == ["User-visible failure", "Correct replacement"]
  end

  test "times out instead of blocking the interview picker" do
    model =
      %Model{
        id: :slow_fake,
        label: "slow fake",
        kind: :cli,
        status: :ready,
        run: fn _prompt, _opts, _on_chunk -> Process.sleep(:infinity) end
      }

    assert {:error, :timeout} =
             InterviewOptionGenerator.generate("What should this clarify?", model, timeout_ms: 10)
  end

  test "does not call unavailable models" do
    assert {:error, :model_unavailable} =
             InterviewOptionGenerator.generate(
               "What should this clarify?",
               scripted_model("- A | B", :unavailable)
             )
  end
end
