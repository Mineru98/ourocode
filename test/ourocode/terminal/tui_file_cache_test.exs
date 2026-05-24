defmodule Ourocode.Terminal.TuiFileCacheTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.TuiFileCache

  setup do
    state = start_supervised!({Agent, fn -> %{file_cache: nil} end})
    %{state: state}
  end

  test "returns cached files without starting discovery", %{state: state} do
    TuiFileCache.put(state, ["lib/a.ex"])

    assert TuiFileCache.get_or_start(state, self(), fn ->
             send(self(), :unexpected_discovery)
             ["lib/b.ex"]
           end) == ["lib/a.ex"]

    refute_received :unexpected_discovery
  end

  test "returns empty while cache is loading", %{state: state} do
    Agent.update(state, &%{&1 | file_cache: :loading})

    assert TuiFileCache.get_or_start(state, self(), fn ->
             send(self(), :unexpected_discovery)
             []
           end) == []

    refute_received :unexpected_discovery
  end

  test "marks an empty cache as loading and sends discovered files to owner", %{state: state} do
    owner = self()

    assert TuiFileCache.get_or_start(state, owner, fn -> ["lib/a.ex", "test/a_test.exs"] end) ==
             []

    assert Agent.get(state, & &1.file_cache) == :loading
    assert_receive {:file_cache_ready, ["lib/a.ex", "test/a_test.exs"]}, 100
  end
end
