defmodule Ourocode.Dashboard.ChildSessionIdentity do
  @moduledoc """
  Stable pane identity helpers for child-session dashboard projections.
  """

  @type pane_key :: String.t()
  @type child_pane_registry :: %{optional(String.t()) => pane_key()}

  @spec register_child_id(child_pane_registry(), String.t()) :: child_pane_registry()
  def register_child_id(registry, child_id) when is_map(registry) and is_binary(child_id) do
    child_id = registry_child_id(child_id)
    Map.put_new(registry, child_id, pane_id(child_id))
  end

  @spec register_child_id(child_pane_registry(), String.t(), map() | nil) ::
          child_pane_registry()
  def register_child_id(registry, child_id, %{id: pane_id})
      when is_map(registry) and is_binary(child_id) and is_binary(pane_id) do
    child_id = registry_child_id(child_id)
    Map.put_new(registry, child_id, pane_id)
  end

  def register_child_id(registry, child_id, _reusable_pane),
    do: register_child_id(registry, child_id)

  @spec child_pane_key(child_pane_registry(), String.t()) :: pane_key()
  def child_pane_key(registry, child_id) when is_map(registry) and is_binary(child_id) do
    child_id = registry_child_id(child_id)

    registry
    |> register_child_id(child_id)
    |> Map.fetch!(child_id)
  end

  @spec child_pane_id(String.t()) :: String.t()
  def child_pane_id(child_id) when is_binary(child_id), do: pane_id(registry_child_id(child_id))

  @spec registry_child_id(String.t()) :: String.t()
  def registry_child_id(child_id) when is_binary(child_id) do
    case String.trim(child_id) do
      "" -> child_id
      trimmed -> trimmed
    end
  end

  @spec pane_id(String.t()) :: String.t()
  def pane_id(child_id), do: "child-session:" <> child_id
end
