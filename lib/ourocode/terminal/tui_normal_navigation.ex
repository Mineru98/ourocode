defmodule Ourocode.Terminal.TuiNormalNavigation do
  @moduledoc false

  alias Ourocode.Terminal.{TuiCompletions, TuiState}

  @spec move_vertical(pid(), -1 | 1, boolean()) :: :ok
  def move_vertical(state, direction, test_run?) when direction in [-1, 1] do
    if suggestion_active?(state, test_run?) do
      TuiState.put_pidx(state, TuiState.pidx(state) + direction)
    else
      TuiState.move_history(state, direction)
    end
  end

  @spec suggestion_active?(pid(), boolean()) :: boolean()
  def suggestion_active?(state, test_run?) do
    TuiCompletions.file_mention_suggesting?(state) or
      TuiCompletions.ooo_suggesting?(state, test_run?)
  end
end
