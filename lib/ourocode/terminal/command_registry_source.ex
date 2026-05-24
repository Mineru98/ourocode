defmodule Ourocode.Terminal.CommandRegistrySource do
  @moduledoc """
  Resolves the command registry visible to terminal slash-command handling.
  """

  alias Ourocode.Command.Registry, as: CommandRegistry

  @doc """
  Returns a command registry from startup/runtime/context state or builtins.
  """
  @spec default_registry(map()) :: {:ok, map()} | {:error, term()}
  def default_registry(%{commands: %{entries: entries, aliases: aliases} = registry})
      when is_map(entries) and is_map(aliases),
      do: {:ok, registry}

  def default_registry(%{runtime: %{commands: %{entries: entries, aliases: aliases} = registry}})
      when is_map(entries) and is_map(aliases),
      do: {:ok, registry}

  def default_registry(%{
        context: %{runtime: %{commands: %{entries: entries, aliases: aliases} = registry}}
      })
      when is_map(entries) and is_map(aliases),
      do: {:ok, registry}

  def default_registry(_startup_result), do: CommandRegistry.load_builtin()

  @doc """
  Adds contextual command actions for the current terminal state.
  """
  @spec contextual_registry(map()) :: {:ok, map()} | {:error, term()}
  def contextual_registry(%{startup_result: startup_result} = state) do
    with {:ok, registry} <- default_registry(startup_result) do
      CommandRegistry.expose_contextual_actions(registry,
        focus_state: Map.get(state, :focus_state),
        pane_model: Map.get(state, :pane_model)
      )
    end
  end
end
