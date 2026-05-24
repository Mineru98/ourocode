defmodule Ourocode.Terminal.InputKillRingTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InputKillRing

  test "killed_text extracts text removed by kill commands" do
    assert InputKillRing.killed_text("hello world", 6, %{key: :ctrl_u}) == "hello "
    assert InputKillRing.killed_text("hello world", 6, %{key: :ctrl_k}) == "world"
    assert InputKillRing.killed_text("hello world", 11, %{key: :ctrl_w}) == "world"
    assert InputKillRing.killed_text("hello world", 5, %{key: :alt_d}) == " world"
    assert InputKillRing.killed_text("hello world", 5, %{key: :left}) == ""
  end

  test "push starts and accumulates kill ring entries by direction" do
    state = base_state(%{kill_ring: []})

    assert %{kill_ring: ["world"]} = InputKillRing.push(state, "world", %{key: :ctrl_k}, false)

    assert %{kill_ring: ["hello world"]} =
             state
             |> Map.put(:kill_ring, ["world"])
             |> InputKillRing.push("hello ", %{key: :ctrl_u}, true)

    assert %{kill_ring: ["world!"]} =
             state
             |> Map.put(:kill_ring, ["world"])
             |> InputKillRing.push("!", %{key: :ctrl_k}, true)
  end

  test "yank inserts the latest kill at the cursor" do
    state = base_state(%{buffer: "hello ", cursor: 6, kill_ring: ["world"]})

    assert %{buffer: "hello world", cursor: 11, kill_index: 0, last_yank: {6, 5}} =
             InputKillRing.yank(state)
  end

  test "rotate_yank replaces the previous yank with the next kill entry" do
    state =
      base_state(%{
        buffer: "hello world",
        cursor: 11,
        kill_ring: ["world", "there"],
        kill_index: 0,
        last_yank: {6, 5}
      })

    assert %{buffer: "hello there", cursor: 11, kill_index: 1, last_yank: {6, 5}} =
             InputKillRing.rotate_yank(state)
  end

  defp base_state(overrides) do
    Map.merge(
      %{
        buffer: "",
        cursor: 0,
        kill_ring: [],
        kill_index: 0,
        last_yank: nil
      },
      overrides
    )
  end
end
