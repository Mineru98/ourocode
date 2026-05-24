defmodule Ourocode.Runtime.LoopBindingQuestionRouterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Ourocode.Runtime.LoopBindingQuestionRouter

  test "returns router decision when it completes before timeout" do
    router_fun = fn _question, _ctx, _model, _opts ->
      {:answer, "ANSWER: use OTP", :model}
    end

    assert LoopBindingQuestionRouter.decide("Architecture?", %{}, :model, 50,
             router_fun: router_fun
           ) == {:answer, "ANSWER: use OTP", :model}
  end

  test "falls back to asking user on timeout and emits trace" do
    parent = self()

    router_fun = fn _question, _ctx, _model, _opts ->
      Process.sleep(50)
      {:answer, "late", :model}
    end

    assert LoopBindingQuestionRouter.decide("What should we do?", %{}, :model, 1,
             router_fun: router_fun,
             on_trace: fn line -> send(parent, {:trace, line}) end
           ) == {:ask_user, "What should we do?", []}

    assert_receive {:trace, "PATH 2 (router timeout 1ms -> user): What should we do?"}
  end

  test "normalizes router task exits" do
    router_fun = fn _question, _ctx, _model, _opts ->
      exit(:boom)
    end

    assert capture_log(fn ->
             assert {:error, {:router_exited, :boom}} =
                      LoopBindingQuestionRouter.decide("Question?", %{}, :model, 5_000,
                        router_fun: router_fun
                      )
           end) =~ ":boom"
  end
end
