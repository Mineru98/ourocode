defmodule Ourocode.Terminal.EventLoopResourcesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.EventLoopResources

  test "release_active accepts ok and ok tuples" do
    assert EventLoopResources.release_active(state(fn _startup, _state -> :ok end)) == :ok

    assert EventLoopResources.release_active(state(fn _startup, _state -> {:ok, :released} end)) ==
             :ok
  end

  test "release_active normalizes callback errors and invalid returns" do
    assert EventLoopResources.release_active(state(fn _startup, _state -> {:error, :busy} end)) ==
             {:error, {:resource_release_failed, :busy}}

    assert EventLoopResources.release_active(state(fn _startup, _state -> :weird end)) ==
             {:error, {:resource_release_failed, {:invalid_result, :weird}}}
  end

  test "release_active catches exceptions and throws" do
    assert {:error, {:resource_release_failed, {:exception, RuntimeError, "boom"}}} =
             EventLoopResources.release_active(state(fn _startup, _state -> raise "boom" end))

    assert EventLoopResources.release_active(state(fn _startup, _state -> throw(:boom) end)) ==
             {:error, {:resource_release_failed, {:caught, :throw, :boom}}}
  end

  defp state(callback) do
    %{startup_result: %{runtime: :fake}, on_release_resources: callback}
  end
end
