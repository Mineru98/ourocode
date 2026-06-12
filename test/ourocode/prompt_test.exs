defmodule Ourocode.PromptTest do
  use ExUnit.Case, async: true

  test "system prompt establishes the ourocode + Ouroboros identity" do
    system = Ourocode.Prompt.system()

    assert system =~ "ourocode"
    assert system =~ "Ouroboros"
    # It must deny the bare-model identity the backends would otherwise claim.
    assert system =~ "you are ourocode"
    assert system == String.trim(system)
  end
end
