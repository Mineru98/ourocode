defmodule Ourocode.Runtime.LoopBindingQuestionRouter do
  @moduledoc false

  alias Ourocode.Runtime.InterviewRouter

  @type decision ::
          {:answer, String.t(), atom()}
          | {:ask_user, String.t(), [map()]}
          | {:error, term()}

  @spec decide(String.t(), map(), term(), non_neg_integer(), keyword()) :: decision()
  def decide(question, ctx, model, timeout_ms, opts)
      when is_binary(question) and is_map(ctx) and is_integer(timeout_ms) do
    router_fun = Keyword.get(opts, :router_fun, &InterviewRouter.decide/4)

    trap_exit? = Process.flag(:trap_exit, true)

    try do
      task =
        Task.async(fn ->
          router_fun.(question, ctx, model, opts)
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, decision} ->
          decision

        {:exit, reason} ->
          {:error, {:router_exited, reason}}

        nil ->
          trace = Keyword.get(opts, :on_trace, fn _line -> :ok end)

          trace.(
            "PATH 2 (router timeout #{timeout_ms}ms -> user): #{String.slice(question, 0, 80)}"
          )

          {:ask_user, question, []}
      end
    after
      Process.flag(:trap_exit, trap_exit?)
    end
  end
end
