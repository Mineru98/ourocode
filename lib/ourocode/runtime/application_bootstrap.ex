defmodule Ourocode.Runtime.ApplicationBootstrap do
  @moduledoc """
  Pure bootstrap preparation helpers for the terminal runtime application.
  """

  @spec session_id(map()) :: String.t()
  def session_id(context) when is_map(context) do
    Map.get_lazy(context, :runtime_session_id, fn ->
      "terminal-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    end)
  end

  @spec prepare(map(), Path.t()) ::
          {:ok, %{required(:project_dir) => Path.t(), required(:journal_path) => Path.t()}}
          | {:error, map()}
  def prepare(context, project_dir) when is_map(context) and is_binary(project_dir) do
    project_dir = Path.expand(project_dir)

    with :ok <- ensure_project_dir(project_dir),
         {:ok, journal_path} <- prepare_journal_path(context, project_dir) do
      {:ok, %{project_dir: project_dir, journal_path: journal_path}}
    end
  end

  @spec default_journal_path(Path.t(), String.t()) :: Path.t()
  def default_journal_path(project_dir, session_id) do
    Path.join([project_dir, ".ourocode", "journals", session_id <> ".jsonl"])
  end

  defp ensure_project_dir(project_dir) do
    if File.dir?(project_dir) do
      :ok
    else
      {:error,
       %{
         status: :unhealthy,
         healthy?: false,
         reason: {:missing_project_dir, project_dir}
       }}
    end
  end

  defp prepare_journal_path(context, project_dir) do
    journal_path =
      context
      |> Map.get(:journal_path, default_journal_path(project_dir, session_id(context)))
      |> Path.expand()

    case File.mkdir_p(Path.dirname(journal_path)) do
      :ok -> {:ok, journal_path}
      {:error, reason} -> {:error, unhealthy(:journal_unavailable, reason)}
    end
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
