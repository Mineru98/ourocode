defmodule Ourocode.Dashboard.HeaderStatusArea do
  @moduledoc """
  Terminal-safe header/status pane for the interactive dashboard.

  The pane is a pure projection of startup/runtime state so the terminal UI can
  render current app and session status without owning runtime state.
  """

  @default_title "ourocode terminal"

  @doc """
  Builds the header/status pane model from a dashboard startup result.
  """
  @spec render(map()) :: map()
  def render(startup_result) when is_map(startup_result) do
    context = Map.get(startup_result, :context, %{})
    runtime = Map.get(startup_result, :runtime) || Map.get(context, :runtime, %{})

    %{
      id: :header_status,
      kind: :terminal_header_status_area,
      title: @default_title,
      app: "ourocode",
      status: Map.get(startup_result, :status, :unknown),
      healthy?: Map.get(startup_result, :healthy?, false),
      runtime_status: runtime_status(runtime),
      session_id: session_id(startup_result, context, runtime),
      project_dir: Map.get(context, :project_dir, "unknown"),
      cwd: Map.get(context, :cwd, "unknown")
    }
  end

  @doc """
  Renders the header/status pane as compact terminal text.
  """
  @spec render_text(map()) :: String.t()
  def render_text(%{id: :header_status} = pane) do
    [
      "+-- #{pane.title}",
      "| app=#{pane.app} status=#{pane.status} runtime=#{pane.runtime_status} session=#{pane.session_id}",
      "| project=#{pane.project_dir}",
      "| cwd=#{pane.cwd}",
      "+--"
    ]
    |> Enum.join("\n")
  end

  defp runtime_status(%{status: status}) when is_atom(status), do: status
  defp runtime_status(%{status: status}) when is_binary(status), do: status
  defp runtime_status(_runtime), do: :unknown

  defp session_id(startup_result, context, runtime) do
    Map.get(runtime, :session_id) ||
      Map.get(context, :runtime_session_id) ||
      Map.get(startup_result, :runtime_session_id) ||
      "none"
  end
end
