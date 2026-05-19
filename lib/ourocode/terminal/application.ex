defmodule Ourocode.Terminal.Application do
  @moduledoc """
  Terminal-native application bootstrap boundary.

  The CLI launcher enters the app through this module. The current baseline
  delegates initial pane/state construction to the dashboard initializer while
  keeping the terminal bootstrap boundary explicit for the persistent prompt
  loop work that follows.
  """

  alias Ourocode.Runtime
  alias Ourocode.Terminal.BrowserRuntimeGuard
  alias Ourocode.Terminal.NetworkListenerGuard
  alias Ourocode.Terminal.{RootUI, ShellRenderer}

  @doc """
  Boots the terminal application with a resolved startup context.
  """
  @spec bootstrap(map()) :: {:ok, map()} | {:error, map()}
  def bootstrap(%{project_dir: project_dir} = context) when is_binary(project_dir) do
    context =
      context
      |> Map.put(:terminal_native?, true)
      |> Map.put_new(:bootstrap_module, __MODULE__)

    with {:ok, browser_runtime_guard} <- BrowserRuntimeGuard.verify_startup_boundary(),
         {:ok, core_interaction_config_guard} <-
           NetworkListenerGuard.verify_core_interaction_config(
             context_config: Map.get(context, :config, %{})
           ),
         {:ok, network_listener_guard_before} <-
           NetworkListenerGuard.verify_startup_boundary(stage: :before_runtime_bootstrap),
         {:ok, runtime} <- Runtime.Application.bootstrap(context) do
      case NetworkListenerGuard.verify_startup_boundary(stage: :after_runtime_bootstrap) do
        {:ok, network_listener_guard_after} ->
          context =
            context
            |> Map.put(:browser_runtime_guard, browser_runtime_guard)
            |> Map.put(:core_interaction_config_guard, core_interaction_config_guard)
            |> Map.put(:network_listener_guard_before, network_listener_guard_before)
            |> Map.put(:network_listener_guard_after, network_listener_guard_after)

          runtime_context = Map.put(context, :runtime, runtime)

          case RootUI.init(runtime_context) do
            {:ok, root_ui} ->
              {:ok,
               root_ui
               |> Map.put(:runtime, runtime)
               |> Map.put(:browser_runtime_guard, browser_runtime_guard)
               |> Map.put(:core_interaction_config_guard, core_interaction_config_guard)
               |> Map.put(:network_listener_guard_before, network_listener_guard_before)
               |> Map.put(:network_listener_guard_after, network_listener_guard_after)
               |> attach_initial_terminal_frame()}

            {:error, reason} ->
              Runtime.Application.stop(runtime)
              {:error, reason}
          end

        {:error, reason} ->
          Runtime.Application.stop(runtime)
          {:error, reason}
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def bootstrap(_context) do
    {:error,
     %{
       status: :unhealthy,
       healthy?: false,
       reason: :invalid_terminal_bootstrap_context
     }}
  end

  defp attach_initial_terminal_frame(root_ui) do
    root_ui
    |> Map.put(:terminal_renderer, ShellRenderer)
    |> Map.put(:initial_terminal_frame_renderer, ShellRenderer)
    |> Map.put(:initial_terminal_frame, ShellRenderer.render_initial_frame(root_ui))
  end
end
