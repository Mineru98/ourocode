defmodule Ourocode.Terminal.ResumeSessions do
  @moduledoc """
  Finds journaled sessions available to the terminal `/resume` command.
  """

  alias Ourocode.Journal
  alias Ourocode.Journal.ReplayLoader

  @actions [:resume_session, :replay_journal]
  @default_limit 8
  @expanded_limit 50

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec dispatch(:resume_session | :replay_journal, map(), map()) ::
          {:ok, map()} | {:error, term()}
  def dispatch(action, command_event, state) when action in @actions do
    run(Map.get(command_event, :args, []), state, Map.fetch!(state, :output))
  end

  @spec run([String.t()], map(), pid()) :: {:ok, map()} | {:error, term()}
  def run(args, state, output) when args in [[], ["--all"]] and is_map(state) do
    sessions = list(state, limit_for_args(args))
    total = session_count(state)
    render_sessions(output, sessions)
    render_more_hint(output, sessions, total)
    {:ok, %{sessions: sessions, total: total}}
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
  def list(state) when is_map(state), do: list(state, @default_limit)

  @spec list(map(), pos_integer()) :: [map()]
  def list(state, limit) when is_map(state) and is_integer(limit) and limit > 0 do
    state
    |> session_files()
    |> Enum.take(limit)
    |> Enum.map(&session_summary/1)
  end

  @spec resolve_path(map(), String.t()) ::
          {:ok, Path.t()} | {:error, {:unknown_resume_session, String.t()}}
  def resolve_path(state, target) when is_map(state) and is_binary(target) do
    sessions = all_session_files(state)

    cond do
      target == "latest" and sessions != [] ->
        {:ok, hd(sessions).path}

      indexed = indexed_session(sessions, target) ->
        {:ok, indexed.path}

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
    IO.puts(output, "resume workspace")
    IO.puts(output, "  status #{length(sessions)} resumable")

    case sessions do
      [latest | _rest] -> IO.puts(output, "  latest #{session_title(latest)}")
      [] -> :ok
    end

    sessions
    |> Enum.with_index(1)
    |> Enum.each(fn {session, index} ->
      IO.puts(output, "  record #{index}")
      IO.puts(output, "    task #{session_title(session)}")
      IO.puts(output, "    state #{session_activity(session)}")
      IO.puts(output, "    updated #{Map.get(session, :updated_label, "unknown")}")
      IO.puts(output, "    action /resume #{index}")
    end)

    IO.puts(output, "  actions /resume latest, /resume <number>, /resume --all")
    :ok
  end

  defp render_more_hint(output, sessions, total) when total > length(sessions) do
    IO.puts(output, "  showing #{length(sessions)} of #{total}; use /resume --all for more")
    IO.puts(output, "  paths hidden; pass an explicit .jsonl path only when needed")
  end

  defp render_more_hint(_output, _sessions, _total), do: :ok

  defp limit_for_args(["--all"]), do: @expanded_limit
  defp limit_for_args(_args), do: @default_limit

  defp session_count(state), do: state |> all_session_files() |> length()

  @spec session_title(map()) :: String.t()
  def session_title(%{title: title}) when is_binary(title) and title != "", do: title

  def session_title(%{id: id}) when is_binary(id) do
    cond do
      String.starts_with?(id, "verify-") -> "Verification run"
      String.starts_with?(id, "headless-") -> "Headless command"
      String.starts_with?(id, "session-") -> "Saved session"
      true -> "Saved workspace"
    end
  end

  def session_title(_session), do: "Saved workspace"

  @spec session_activity(map()) :: String.t()
  def session_activity(%{event_count: 0}), do: "no replay events yet"
  def session_activity(%{event_count: 1}), do: "1 replay event"
  def session_activity(%{event_count: count}) when is_integer(count), do: "#{count} replay events"
  def session_activity(_session), do: "replay state unknown"

  defp indexed_session(sessions, target) do
    case Integer.parse(target) do
      {index, ""} when index > 0 -> Enum.at(sessions, index - 1)
      _other -> nil
    end
  end

  defp session_summary(file) do
    file
    |> Map.take([:id, :path, :mtime])
    |> Map.put(:event_count, event_count(file.path))
    |> Map.put(:updated_label, updated_label(file.mtime))
  end

  defp session_files(state), do: all_session_files(state)

  defp all_session_files(state) do
    state
    |> journal_dir()
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.map(&file_summary/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.mtime, :desc)
  end

  defp file_summary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix) do
      %{id: Path.basename(path, ".jsonl"), path: path, mtime: stat.mtime}
    else
      {:error, _reason} -> nil
    end
  end

  defp event_count(path) do
    case Journal.read_ordered(path) do
      {:ok, events} -> length(events)
      {:error, _reason} -> 0
    end
  end

  defp updated_label(mtime) when is_integer(mtime) do
    delta = max(System.system_time(:second) - mtime, 0)

    cond do
      delta < 60 -> "#{delta}s ago"
      delta < 3_600 -> "#{div(delta, 60)}m ago"
      delta < 86_400 -> "#{div(delta, 3_600)}h ago"
      true -> "#{div(delta, 86_400)}d ago"
    end
  end

  defp updated_label(_mtime), do: "unknown"
end
