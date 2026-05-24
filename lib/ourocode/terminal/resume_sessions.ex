defmodule Ourocode.Terminal.ResumeSessions do
  @moduledoc """
  Finds journaled sessions available to the terminal `/resume` command.
  """

  alias Ourocode.Journal
  alias Ourocode.Journal.ReplayLoader

  @actions [:resume_session, :replay_journal]

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec dispatch(:resume_session | :replay_journal, map(), map()) ::
          {:ok, map()} | {:error, term()}
  def dispatch(action, command_event, state) when action in @actions do
    run(Map.get(command_event, :args, []), state, Map.fetch!(state, :output))
  end

  @spec run([String.t()], map(), pid()) :: {:ok, map()} | {:error, term()}
  def run([], state, output) when is_map(state) do
    sessions = list(state)
    render_sessions(output, sessions)
    {:ok, %{sessions: sessions}}
  end

  def run([target | _rest], state, output)
      when is_binary(target) and is_map(state) do
    with {:ok, path} <- resolve_path(state, target),
         {:ok, %{events: events, report: report}} <- ReplayLoader.load(path) do
      IO.puts(
        output,
        "resumed #{Path.basename(path, ".jsonl")}: #{length(events)} events replayed"
      )

      {:ok, %{path: path, events: events, report: report}}
    else
      {:error, reason} ->
        {:error, {:resume_session_failed, reason}}
    end
  end

  @spec list(map()) :: [map()]
  def list(state) when is_map(state) do
    state
    |> journal_dir()
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      %{
        id: Path.basename(path, ".jsonl"),
        path: path,
        event_count: event_count(path)
      }
    end)
  end

  @spec resolve_path(map(), String.t()) ::
          {:ok, Path.t()} | {:error, {:unknown_resume_session, String.t()}}
  def resolve_path(state, target) when is_map(state) and is_binary(target) do
    sessions = list(state)

    cond do
      session = Enum.find(sessions, &(&1.id == target)) ->
        {:ok, session.path}

      File.regular?(target) ->
        {:ok, target}

      true ->
        {:error, {:unknown_resume_session, target}}
    end
  end

  @spec journal_dir(map()) :: Path.t()
  def journal_dir(%{journal_path: path}) when is_binary(path), do: Path.dirname(path)

  def journal_dir(%{startup_result: startup_result}) do
    startup_result
    |> get_in([:runtime, :journal, :path])
    |> case do
      path when is_binary(path) -> Path.dirname(path)
      _other -> Path.join([File.cwd!(), ".ourocode", "journals"])
    end
  end

  def journal_dir(_state), do: Path.join([File.cwd!(), ".ourocode", "journals"])

  @spec render_sessions(pid(), [map()]) :: :ok
  def render_sessions(output, []) do
    IO.puts(output, "resume: no journaled sessions found")
    :ok
  end

  def render_sessions(output, sessions) when is_list(sessions) do
    IO.puts(output, "resume: journaled sessions")

    Enum.each(sessions, fn session ->
      IO.puts(output, "  #{session.id} events=#{session.event_count} path=#{session.path}")
    end)

    :ok
  end

  defp event_count(path) do
    case Journal.read_ordered(path) do
      {:ok, events} -> length(events)
      {:error, _reason} -> 0
    end
  end
end
