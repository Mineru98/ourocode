defmodule Ourocode.Terminal.TuiModelSelectionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Terminal.{TuiModelSelection, TuiState}

  test "selected wraps an unbounded picker index across available models" do
    models = [model(:alpha, "alpha"), model(:bravo, "bravo"), model(:charlie, "charlie")]

    assert %Model{id: :alpha} = TuiModelSelection.selected(models, 0)
    assert %Model{id: :bravo} = TuiModelSelection.selected(models, 4)
    assert %Model{id: :charlie} = TuiModelSelection.selected(models, -1)
    assert TuiModelSelection.selected([], 10) == nil
  end

  test "choose stores ready model selection, logs it, and closes model mode" do
    state = TuiState.start_link()
    TuiState.put_mode(state, :model)
    TuiState.put_pidx(state, 1)
    {:ok, output} = StringIO.open("")

    TuiModelSelection.choose(%{}, output, state, 80, 24,
      models: [model(:alpha, "alpha"), model(:bravo, "bravo")],
      redraw: fn _result, _output, _state, _buffer, _cols, _rows -> :ok end,
      login: fn _result, _output, _state, _cols, _rows, _redraw -> :ok end
    )

    {_input, captured} = StringIO.contents(output)
    current = Agent.get(state, & &1)

    assert captured =~ "model: bravo"
    assert current.model_id == :bravo
    assert current.mode == :normal
    assert current.pidx == 0
  end

  test "choose delegates codex auth-needed model to login flow" do
    state = TuiState.start_link()
    TuiState.put_mode(state, :model)
    {:ok, output} = StringIO.open("")
    parent = self()

    TuiModelSelection.choose(%{}, output, state, 80, 24,
      models: [model(:codex, "codex", {:needs_auth, "/login"})],
      redraw: fn _result, _output, _state, _buffer, _cols, _rows -> :ok end,
      login: fn _result, _output, _state, cols, rows, _redraw ->
        send(parent, {:login_started, cols, rows})
      end
    )

    assert_receive {:login_started, 80, 24}
    assert Agent.get(state, & &1.model_id) == :codex
  end

  defp model(id, label, status \\ :ready) do
    %Model{
      id: id,
      label: label,
      kind: :cli,
      status: status,
      run: fn _prompt, _opts, _on_chunk -> {:ok, ""} end
    }
  end
end
