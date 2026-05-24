defmodule Ourocode.Terminal.CommandRegistrySourceTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.FocusState
  alias Ourocode.Terminal.CommandRegistrySource
  alias Ourocode.Terminal.FocusNavigation

  test "resolves command registry from direct runtime or context runtime state" do
    direct = registry("direct")
    runtime = registry("runtime")
    context_runtime = registry("context-runtime")

    assert CommandRegistrySource.default_registry(%{commands: direct}) == {:ok, direct}

    assert CommandRegistrySource.default_registry(%{runtime: %{commands: runtime}}) ==
             {:ok, runtime}

    assert CommandRegistrySource.default_registry(%{
             context: %{runtime: %{commands: context_runtime}}
           }) == {:ok, context_runtime}
  end

  test "falls back to builtin registry and exposes contextual actions" do
    assert {:ok, registry} = CommandRegistrySource.default_registry(%{})
    assert Enum.any?(registry.ordered, &(&1.slash == "/help"))

    assert {:ok, contextual} =
             CommandRegistrySource.contextual_registry(%{
               startup_result: %{},
               focus_state: FocusState.new(),
               pane_model: FocusNavigation.default_pane_model()
             })

    assert Enum.any?(contextual.ordered, &(&1.slash == "/help"))
  end

  defp registry(id) do
    %{entries: %{}, aliases: %{}, ordered: [], status: :loaded, loaded_count: 0, sources: [id]}
  end
end
