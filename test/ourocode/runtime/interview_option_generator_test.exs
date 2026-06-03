defmodule Ourocode.Runtime.InterviewOptionGeneratorTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Runtime.InterviewOptionGenerator

  test "generates options with the active main-session model" do
    model =
      scripted_model("""
      - 질문이 이어진다 | 답변 후 다음 질문과 선택지가 생성되는지 본다
      - 답변이 반영된다 | 이전 답변이 다음 질문 맥락에 남는지 본다
      """)

    assert {:ok, options} =
             InterviewOptionGenerator.generate(
               "ooo interview가 질문을 이어가고 답변을 반영하는지 어떻게 볼까요?",
               model
             )

    assert Enum.map(options, & &1.label) == ["질문이 이어진다", "답변이 반영된다"]
  end

  test "returns an error instead of inventing choices when the model gives no option lines" do
    model = scripted_model("ASK_USER What should happen next?")

    assert {:error, :no_options} =
             InterviewOptionGenerator.generate("What should happen next?", model)
  end

  defp scripted_model(reply) do
    %Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn _prompt, _opts, on_chunk ->
        if is_function(on_chunk, 1), do: on_chunk.(reply)
        {:ok, reply}
      end
    }
  end
end
