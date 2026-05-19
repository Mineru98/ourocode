defmodule Ourocode.Terminal.RootUI do
  @moduledoc """
  Root terminal UI initializer.

  This is the terminal-native UI boundary that owns the first render model the
  CLI receives after runtime startup. The current baseline reuses the dashboard
  pane projection, but callers enter it through this module so later terminal
  concerns can evolve without bypassing the terminal application boundary.
  """

  alias Ourocode.Dashboard

  @doc """
  Initializes the root terminal UI model from a bootstrapped runtime context.
  """
  @spec init(map()) :: {:ok, map()} | {:error, map()}
  def init(%{project_dir: project_dir} = context) when is_binary(project_dir) do
    context =
      context
      |> Map.put(:root_ui_module, __MODULE__)
      |> Map.put_new(:ui_surface, :terminal)

    case Dashboard.Application.init(context) do
      {:ok, root_ui} ->
        {:ok,
         root_ui
         |> Map.put(:ui_surface, :terminal)
         |> Map.put(:root_ui_module, __MODULE__)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def init(_context) do
    {:error,
     %{
       status: :unhealthy,
       healthy?: false,
       reason: :invalid_root_ui_context
     }}
  end
end
