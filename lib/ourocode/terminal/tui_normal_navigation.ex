defmodule Ourocode.Terminal.TuiNormalNavigation do
  @moduledoc false

  alias Ourocode.Terminal.{TuiCompletions, TuiState}

  @spec move_vertical(pid(), -1 | 1, boolean()) :: :ok
  def move_vertical(state, direction, test_run?) when direction in [-1, 1] do
    cond do
      suggestion_active?(state, test_run?) ->
        TuiState.put_pidx(state, TuiState.pidx(state) + direction)

      workspace_navigable?(state) ->
        TuiState.move_workspace(state, direction)

      true ->
        TuiState.move_history(state, direction)
    end
  end

  defp workspace_navigable?(state) do
    TuiState.buffer(state) == "" and TuiState.workspace_active?(state)
  end

  @spec suggestion_active?(pid(), boolean()) :: boolean()
  def suggestion_active?(state, test_run?) do
    TuiCompletions.file_mention_suggesting?(state) or
      TuiCompletions.ooo_suggesting?(state, test_run?)
  end
end
