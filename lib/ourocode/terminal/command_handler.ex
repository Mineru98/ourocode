defmodule Ourocode.Terminal.CommandHandler do
  @moduledoc """
  Default slash-command handling for the terminal event loop.
  """

  alias Ourocode.Command.Registry, as: CommandRegistry
  alias Ourocode.Terminal.CommandActionDispatcher
  alias Ourocode.Terminal.CommandInput
  alias Ourocode.Terminal.CommandRegistrySource

  @spec registry(map()) :: {:ok, map()} | {:error, term()}
  def registry(%{startup_result: _startup_result} = state) do
    CommandRegistrySource.contextual_registry(state)
  end

  @spec handle(map(), map()) :: :ok | {:ok, term()} | {:error, term()}
  def handle(command_event, state) when is_map(command_event) and is_map(state) do
    with {:ok, registry} <- registry(state),
         {:ok, entry} <- CommandRegistry.fetch(registry, command_event.command) do
      dispatch_builtin(command_event, entry, state, registry)
    else
      :error -> {:error, unknown_command_reason(command_event.command, state)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec default_registry(map()) :: {:ok, map()} | {:error, term()}
  def default_registry(startup_result), do: CommandRegistrySource.default_registry(startup_result)

  defp unknown_command_reason(command, state) do
    with {:ok, registry} <- registry(state) do
      CommandInput.unknown_command_reason(command, registry)
    else
      _error -> {:unknown_command, command, []}
    end
  end

  defp dispatch_builtin(command_event, %{run_spec: run_spec} = entry, state, registry) do
    command_event =
      command_event
      |> Map.put(:run_spec, run_spec)
      |> Map.put(:command_entry, entry)

    CommandActionDispatcher.dispatch(
      Map.get(run_spec, :action),
      command_event,
      entry,
      state,
      registry
    )
  end
end
