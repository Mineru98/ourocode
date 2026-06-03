defmodule Ourocode.Runtime.ApplicationServices do
  @moduledoc """
  OTP service supervision setup for one runtime application session.
  """

  alias Ourocode.Plugin.ConfigWatcher
  alias Ourocode.Plugin.UserLevel.Registry, as: UserLevelRegistry
  alias Ourocode.Runtime.ApplicationState

  @spec start(map(), Path.t(), Path.t()) ::
          {:ok, pid(), map(), atom()} | {:error, map()}
  def start(context, project_dir, journal_path)
      when is_map(context) and is_binary(project_dir) and is_binary(journal_path) do
    registry_name = unique_registry_name()

    case Supervisor.start_link(children(context, project_dir, journal_path, registry_name),
           strategy: :one_for_one
         ) do
      {:ok, supervisor_pid} ->
        Process.unlink(supervisor_pid)
        {:ok, supervisor_pid, service_pids(supervisor_pid), registry_name}

      {:error, reason} ->
        {:error, unhealthy(:runtime_supervision_unavailable, reason)}
    end
  end

  @spec children(map(), Path.t(), Path.t(), atom()) :: [Supervisor.child_spec()]
  def children(context, project_dir, journal_path, registry_name)
      when is_map(context) and is_binary(project_dir) and is_binary(journal_path) and
             is_atom(registry_name) do
    [
      Supervisor.child_spec({Registry, keys: :unique, name: registry_name},
        id: :runtime_registry
      ),
      Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one},
        id: :transport_supervisor
      ),
      Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one}, id: :session_supervisor),
      Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one}, id: :child_supervisor),
      agent_child(:event_pipeline, ApplicationState.event_pipeline_state(context.config)),
      agent_child(:pane_model, ApplicationState.pane_model_state()),
      agent_child(:focus_state, ApplicationState.focus_state()),
      agent_child(:plugin_registry, ApplicationState.plugin_state(context)),
      Supervisor.child_spec({UserLevelRegistry, name: nil}, id: :user_level_plugin_registry),
      Supervisor.child_spec(
        {ConfigWatcher,
         ApplicationState.plugin_config_watcher_options(context, project_dir, journal_path)},
        id: :plugin_config_watcher
      ),
      agent_child(:command_registry, ApplicationState.command_registry_state(context)),
      agent_child(:queued_notifications, ApplicationState.queued_notification_state()),
      agent_child(:hook_lifecycle, ApplicationState.hook_lifecycle_state()),
      agent_child(:wonder_tool, ApplicationState.wonder_tool_state(project_dir, journal_path))
    ]
  end

  @spec service_pids(pid()) :: map()
  def service_pids(supervisor_pid) when is_pid(supervisor_pid) do
    supervisor_pid
    |> Supervisor.which_children()
    |> Enum.reduce(%{}, fn {id, pid, _type, _modules}, acc ->
      if id in ApplicationState.service_ids() and is_pid(pid),
        do: Map.put(acc, id, pid),
        else: acc
    end)
  end

  defp agent_child(id, initial_state) do
    Supervisor.child_spec({Agent, fn -> initial_state end}, id: id)
  end

  defp unique_registry_name do
    :"ourocode_runtime_registry_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp unhealthy(reason, details) do
    %{
      status: :unhealthy,
      healthy?: false,
      reason: reason,
      details: details
    }
  end
end
