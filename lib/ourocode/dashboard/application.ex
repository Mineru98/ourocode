defmodule Ourocode.Dashboard.Application do
  @moduledoc """
  Startup boundary for the interactive ourocode dashboard.

  The full dashboard supervision tree will attach here. For startup, this
  initializer receives the resolved project context from the CLI and returns
  the compact dashboard state expected by later runtime work.
  """

  alias Ourocode.Dashboard.{Layout, SessionListPane, TaskPromptInput}

  @doc """
  Initializes the dashboard with the resolved implementation project context.
  """
  def init(%{project_dir: project_dir} = context) when is_binary(project_dir) do
    project_dir = Path.expand(project_dir)
    context = Map.put(context, :project_dir, project_dir)

    if File.dir?(project_dir) do
      config = Map.get(context, :config, Ourocode.Config.defaults())
      context = Map.put(context, :config, config)

      {:ok,
       %{
         status: :healthy,
         healthy?: true,
         runtime_source: "ourocode",
         context: context,
         config: config,
         prompt_placeholder: "Describe a task for a new session",
         panes: initial_pane_state(),
         health: %{
           project_dir: :ok,
           dashboard_state: :ok,
           checked_at_ms: System.monotonic_time(:millisecond)
         }
       }}
    else
      {:error,
       %{
         status: :unhealthy,
         healthy?: false,
         reason: {:missing_project_dir, project_dir},
         context: context
       }}
    end
  end

  def init(_context) do
    {:error,
     %{
       status: :unhealthy,
       healthy?: false,
       reason: :invalid_project_context
     }}
  end

  defp initial_pane_state do
    %{
      working: SessionListPane.render([]),
      completed: SessionListPane.render_completed([]),
      task_prompt: TaskPromptInput.render(),
      focused: nil,
      open: []
    }
    |> Layout.apply_compact_session_list_layout()
  end
end
