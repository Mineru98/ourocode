defmodule Ourocode.Terminal.CommandInputErrorTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.CommandInputError

  test "formats unknown command errors with and without suggestions" do
    assert CommandInputError.format({:unknown_command, "/capabilites", ["/capabilities"]}) ==
             "unknown command /capabilites. did you mean /capabilities?"

    assert CommandInputError.format({:unknown_command, "/bogus", []}) ==
             "unknown command /bogus"
  end

  test "passes through string errors and inspects structured errors" do
    assert CommandInputError.format("already formatted") == "already formatted"

    assert CommandInputError.format({:selection_out_of_range, 99}) ==
             "{:selection_out_of_range, 99}"
  end
end
