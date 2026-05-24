defmodule Ourocode.Terminal.LiveResult do
  @moduledoc """
  Safely merges a live pane snapshot into a terminal render result.
  """

  @spec result(map()) :: map()
  def result(%{pane_snapshot: snapshot} = result) when is_function(snapshot, 0) do
    case snapshot.() do
      %{} = live -> Map.merge(result, live)
      _other -> result
    end
  rescue
    _exception -> result
  end

  def result(result), do: result
end
