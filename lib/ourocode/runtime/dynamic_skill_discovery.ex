defmodule Ourocode.Runtime.DynamicSkillDiscovery do
  @moduledoc """
  Applies dynamically discovered skills to the supervised command registry.
  """

  alias Ourocode.Command.Registry, as: CommandRegistry
  alias Ourocode.Journal

  @spec discover(map(), map() | [map()] | nil, keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def discover(runtime, skills, options \\ [])

  def discover(
        %{
          services: %{command_registry: command_registry_pid},
          journal: %{path: journal_path}
        },
        skills,
        options
      )
      when is_pid(command_registry_pid) and is_binary(journal_path) do
    options = Map.new(options)
    before_registry = Agent.get(command_registry_pid, & &1)

    with {:ok, updated_registry} <- CommandRegistry.add_dynamic_skills(before_registry, skills),
         update_event <-
           command_registry_update_event(before_registry, updated_registry, skills, options),
         :ok <- Journal.append(journal_path, update_event) do
      Agent.update(command_registry_pid, fn _registry -> updated_registry end)

      {:ok,
       %{
         registry: updated_registry,
         event: update_event,
         accepted_entries: accepted_command_entries(before_registry, updated_registry),
         duplicate_count_delta:
           Map.get(updated_registry, :duplicate_count, 0) -
             Map.get(before_registry, :duplicate_count, 0),
         journal_path: journal_path
       }}
    end
  end

  def discover(_runtime, _skills, _options) do
    {:error, :command_registry_unavailable}
  end

  defp command_registry_update_event(before_registry, updated_registry, skills, options) do
    accepted_entries = accepted_command_entries(before_registry, updated_registry)

    %{
      type: :command_registry_updated,
      event_type: :command_registry_updated,
      source: :command_registry,
      occurred_at_ms: Map.get(options, :occurred_at_ms, System.system_time(:millisecond)),
      session_id: Map.get(options, :session_id),
      payload: %{
        reason: Map.get(options, :reason, :dynamic_skill_discovery),
        discovered_from: Map.get(options, :discovered_from, "dynamic_skill_discovery"),
        discovered_count: skills |> List.wrap() |> Enum.count(&is_map/1),
        accepted_count: length(accepted_entries),
        accepted_slashes: Enum.map(accepted_entries, & &1.slash),
        accepted_entries: Enum.map(accepted_entries, &command_registry_event_entry/1),
        sources: Map.get(updated_registry, :sources, []),
        loaded_count: Map.get(updated_registry, :loaded_count, 0),
        duplicate_count: Map.get(updated_registry, :duplicate_count, 0),
        duplicate_count_delta:
          Map.get(updated_registry, :duplicate_count, 0) -
            Map.get(before_registry, :duplicate_count, 0)
      }
    }
  end

  defp accepted_command_entries(before_registry, updated_registry) do
    before_slashes = before_registry |> Map.get(:entries, %{}) |> Map.keys() |> MapSet.new()

    updated_registry
    |> Map.get(:ordered, [])
    |> Enum.filter(
      &(&1.source == :dynamic_skill and not MapSet.member?(before_slashes, &1.slash))
    )
  end

  defp command_registry_event_entry(entry) do
    %{
      id: entry.id,
      name: entry.name,
      slash: entry.slash,
      aliases: entry.aliases,
      source: entry.source,
      source_id: entry.source_id,
      category: entry.category,
      availability: entry.availability,
      runnable?: entry.runnable?,
      run_spec: entry.run_spec
    }
  end
end
