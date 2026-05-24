defmodule Ourocode.Dashboard.ChildSessionPaneState do
  @moduledoc """
  Shared helpers for the child-session pane projection state.
  """

  @spec new() :: map()
  def new do
    %{working: [], completed: [], focused: nil, open: [], child_pane_registry: %{}}
  end

  @spec registry(map()) :: map()
  def registry(%{child_pane_registry: registry}) when is_map(registry), do: registry
  def registry(_state), do: %{}
end
