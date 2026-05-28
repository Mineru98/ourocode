defmodule Ourocode.Terminal.PromptActivityIndicatorTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.PromptActivityIndicator

  test "cycles through rapid three-cell prompt activity frames" do
    assert PromptActivityIndicator.frames() == ["■⬝⬝", "■■⬝", "⬝■■", "⬝⬝■"]
    assert PromptActivityIndicator.frame(0) == "■⬝⬝"
    assert PromptActivityIndicator.frame(1) == "■■⬝"
    assert PromptActivityIndicator.frame(4) == "■⬝⬝"
  end
end
