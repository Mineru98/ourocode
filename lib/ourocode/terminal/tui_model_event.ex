defmodule Ourocode.Terminal.TuiModelEvent do
  @moduledoc """
  Key handling while the model picker is active.
  """

  alias Ourocode.Terminal.{TuiPalette, TuiState}

  @spec handle(map(), pid(), map(), (-> any()), (-> any())) ::
          :continue | :exit | {:submit, String.t()}
  def handle(%{key: :escape}, state, _callbacks, draw, cont) do
    TuiPalette.close(state)
    draw.()
    cont.()
  end

  def handle(%{key: k}, state, _callbacks, draw, cont) when k in [:down, :tab] do
    TuiState.put_pidx(state, TuiState.pidx(state) + 1)
    draw.()
    cont.()
  end

  def handle(%{key: :up}, state, _callbacks, draw, cont) do
    TuiState.put_pidx(state, TuiState.pidx(state) - 1)
    draw.()
    cont.()
  end

  def handle(%{key: :enter}, _state, callbacks, _draw, cont) do
    Map.fetch!(callbacks, :choose_model).()
    cont.()
  end

  def handle(%{key: :backspace}, state, _callbacks, draw, cont) do
    TuiPalette.close(state)
    draw.()
    cont.()
  end

  def handle(_event, _state, _callbacks, _draw, cont), do: cont.()
end
