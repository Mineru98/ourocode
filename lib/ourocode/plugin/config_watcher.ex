defmodule Ourocode.Plugin.ConfigWatcher do
  @moduledoc """
  Watches plugin configuration sources and emits reload requests.

  The watcher is an Elixir-owned runtime process. It does not reload the
  terminal UI and does not own plugin state; it only detects config source file
  create, modify, and delete transitions and emits data-only reload requests for
  the hot-reload boundary to consume.
  """

  use GenServer

  alias Ourocode.Config
  alias Ourocode.Journal

  @default_poll_interval_ms 1_000

  @type change :: :created | :modified | :deleted
  @type relevance :: :relevant_config_change | :relevant_plugin_settings_change
  @type source_kind :: :plugin_config | :plugin_settings
  @type source_snapshot :: %{
          required(:path) => Path.t(),
          required(:kind) => source_kind(),
          required(:exists?) => boolean(),
          optional(:plugin_id) => String.t(),
          optional(:size) => non_neg_integer(),
          optional(:mtime) => term(),
          optional(:checksum) => String.t()
        }
  @type reload_request :: %{
          required(:type) => :plugin_config_reload_requested | :plugin_settings_reload_requested,
          required(:event_type) =>
            :plugin_config_reload_requested | :plugin_settings_reload_requested,
          required(:source) => :plugin_config_watcher,
          required(:change) => change(),
          required(:relevance) => relevance(),
          required(:relevant?) => true,
          required(:occurred_at_ms) => integer(),
          required(:reload_boundary) => :elixir_runtime,
          required(:ui_restart_required?) => false,
          required(:request_id) => String.t()
        }

  @doc """
  Starts a config watcher.

  Options:

    * `:project_dir` - project root used for default config source discovery.
    * `:source_paths` - explicit config source paths to watch. Missing files are
      tracked so later creates are detected.
    * `:plugin_setting_paths` - plugin-scoped settings files to watch, as
      `%{plugin_id: id, path: path}` maps, `{id, path}` tuples, or
      `{id, [path, ...]}` tuples.
    * `:poll_interval_ms` - periodic polling interval. Use `false` to disable
      automatic polling and drive detection with `poll/1`.
    * `:subscribers` - PIDs that receive `{:plugin_config_reload_requested, event}`.
    * `:journal_path` - optional JSONL journal path for durable reload requests.
  """
  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options)
  end

  @doc """
  Polls the watched sources immediately and returns emitted reload requests.
  """
  @spec poll(pid() | GenServer.name()) :: {:ok, [reload_request()]} | {:error, term()}
  def poll(watcher) do
    GenServer.call(watcher, :poll)
  end

  @doc """
  Returns the watcher's current data-only state.
  """
  @spec state(pid() | GenServer.name()) :: map()
  def state(watcher), do: GenServer.call(watcher, :state)

  @doc """
  Builds the deterministic source list for plugin config watching.
  """
  @spec source_paths(Path.t(), keyword() | map()) :: [Path.t()]
  def source_paths(project_dir, options \\ []) when is_binary(project_dir) do
    options = options_map(options)

    case Map.get(options, :source_paths) do
      paths when is_list(paths) and paths != [] ->
        paths

      _paths ->
        Config.supported_config_candidates()
        |> Enum.map(&Path.join(project_dir, &1))
    end
    |> Enum.map(&Path.expand(&1, project_dir))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Diffs two source snapshots into create, modify, and delete changes.
  """
  @spec diff_snapshots([source_snapshot()], [source_snapshot()]) :: [
          {change(), source_snapshot()}
        ]
  def diff_snapshots(before_snapshots, after_snapshots)
      when is_list(before_snapshots) and is_list(after_snapshots) do
    before_by_path = Map.new(before_snapshots, &{&1.path, &1})

    after_snapshots
    |> Enum.reduce([], fn after_snapshot, acc ->
      before_snapshot = Map.get(before_by_path, after_snapshot.path)

      case classify_change(before_snapshot, after_snapshot) do
        nil -> acc
        change -> [{change, after_snapshot} | acc]
      end
    end)
    |> Enum.reverse()
  end

  @impl GenServer
  def init(options) do
    options = options_map(options)
    project_dir = options |> Map.get(:project_dir, File.cwd!()) |> Path.expand()
    source_paths = source_paths(project_dir, options)
    watch_sources = watch_sources(project_dir, source_paths, options)

    state = %{
      project_dir: project_dir,
      source_paths: source_paths,
      plugin_setting_paths: plugin_setting_paths(project_dir, options),
      watch_sources: watch_sources,
      snapshots: snapshot_sources(watch_sources),
      subscribers: Map.get(options, :subscribers, []),
      journal_path: Map.get(options, :journal_path),
      poll_interval_ms: Map.get(options, :poll_interval_ms, @default_poll_interval_ms),
      watcher_id: Map.get_lazy(options, :watcher_id, &default_watcher_id/0),
      emitted_count: 0,
      last_reload_requests: [],
      ui_process_restart_count: 0
    }

    schedule_poll(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:poll, _from, state) do
    {events, state} = poll_sources(state)
    {:reply, {:ok, events}, state}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {_events, state} = poll_sources(state)
    schedule_poll(state)
    {:noreply, state}
  end

  defp poll_sources(state) do
    next_snapshots = snapshot_sources(state.watch_sources)
    changes = diff_snapshots(state.snapshots, next_snapshots)

    events =
      Enum.map(changes, fn {change, snapshot} ->
        reload_request_event(state, change, snapshot)
      end)

    emitted_events = Enum.map(events, &emit_event(state, &1))

    state =
      state
      |> Map.put(:snapshots, next_snapshots)
      |> Map.put(:last_reload_requests, emitted_events)
      |> Map.update!(:emitted_count, &(&1 + length(emitted_events)))

    {emitted_events, state}
  end

  defp emit_event(state, event) do
    event =
      case state.journal_path do
        path when is_binary(path) ->
          case Journal.append_returning_event(path, event) do
            {:ok, journaled_event} -> journaled_event
            {:error, reason} -> Map.put(event, :journal_error, reason)
          end

        _path ->
          event
      end

    Enum.each(state.subscribers, fn
      pid when is_pid(pid) -> send(pid, {event.type, event})
      _subscriber -> :ok
    end)

    event
  end

  defp reload_request_event(state, change, snapshot) do
    occurred_at_ms = System.system_time(:millisecond)
    relative_path = Path.relative_to(snapshot.path, state.project_dir)

    base_event = %{
      type: :plugin_config_reload_requested,
      event_type: :plugin_config_reload_requested,
      source: :plugin_config_watcher,
      change: change,
      relevance: classify_relevance(change, snapshot),
      relevant?: true,
      config_source_exists?: snapshot.exists?,
      config_source_signature: Map.take(snapshot, [:exists?, :size, :mtime, :checksum]),
      occurred_at_ms: occurred_at_ms,
      reload_boundary: :elixir_runtime,
      ui_restart_required?: false,
      watcher_id: state.watcher_id,
      request_id:
        reload_request_id(state.watcher_id, snapshot.kind, relative_path, change, occurred_at_ms)
    }

    case snapshot.kind do
      :plugin_settings ->
        base_event
        |> Map.merge(%{
          type: :plugin_settings_reload_requested,
          event_type: :plugin_settings_reload_requested,
          relevance: :relevant_plugin_settings_change,
          reason: :plugin_scoped_settings_changed,
          plugin_id: snapshot.plugin_id,
          settings_source_path: snapshot.path,
          settings_source_relative_path: relative_path,
          settings_source_exists?: snapshot.exists?,
          settings_source_signature: Map.take(snapshot, [:exists?, :size, :mtime, :checksum])
        })
        |> Map.delete(:config_source_exists?)
        |> Map.delete(:config_source_signature)

      _kind ->
        Map.merge(base_event, %{
          reason: :plugin_config_source_changed,
          config_source_path: snapshot.path,
          config_source_relative_path: relative_path
        })
    end
  end

  defp watch_sources(project_dir, source_paths, options) do
    config_sources =
      Enum.map(source_paths, fn path ->
        %{kind: :plugin_config, path: Path.expand(path, project_dir)}
      end)

    config_sources ++ plugin_setting_paths(project_dir, options)
  end

  defp snapshot_sources(sources) do
    Enum.map(sources, &snapshot_source/1)
  end

  defp snapshot_source(%{path: path} = source) do
    expanded_path = Path.expand(path)
    metadata = source |> Map.take([:kind, :plugin_id]) |> Map.put(:path, expanded_path)

    case File.stat(expanded_path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        Map.merge(metadata, %{
          exists?: true,
          size: size,
          mtime: mtime,
          checksum: file_checksum(expanded_path)
        })

      {:ok, _stat} ->
        Map.put(metadata, :exists?, false)

      {:error, _reason} ->
        Map.put(metadata, :exists?, false)
    end
  end

  defp classify_change(nil, %{exists?: true}), do: :created
  defp classify_change(nil, %{exists?: false}), do: nil
  defp classify_change(%{exists?: false}, %{exists?: true}), do: :created
  defp classify_change(%{exists?: true}, %{exists?: false}), do: :deleted

  defp classify_change(%{exists?: true} = before_snapshot, %{exists?: true} = after_snapshot) do
    if Map.take(before_snapshot, [:size, :mtime, :checksum]) ==
         Map.take(after_snapshot, [:size, :mtime, :checksum]) do
      nil
    else
      :modified
    end
  end

  defp classify_change(_before_snapshot, _after_snapshot), do: nil

  defp classify_relevance(change, %{kind: :plugin_settings, path: path})
       when change in [:created, :modified, :deleted] and is_binary(path) do
    :relevant_plugin_settings_change
  end

  defp classify_relevance(change, %{path: path})
       when change in [:created, :modified, :deleted] and is_binary(path) do
    :relevant_config_change
  end

  defp schedule_poll(%{poll_interval_ms: false}), do: :ok
  defp schedule_poll(%{poll_interval_ms: nil}), do: :ok

  defp schedule_poll(%{poll_interval_ms: poll_interval_ms})
       when is_integer(poll_interval_ms) and poll_interval_ms > 0 do
    Process.send_after(self(), :poll, poll_interval_ms)
    :ok
  end

  defp schedule_poll(_state), do: :ok

  defp reload_request_id(watcher_id, kind, relative_path, change, occurred_at_ms) do
    [
      reload_request_prefix(kind),
      watcher_id,
      change,
      relative_path,
      occurred_at_ms,
      System.unique_integer([:positive, :monotonic])
    ]
    |> Enum.map(&to_string/1)
    |> Enum.join(":")
  end

  defp reload_request_prefix(:plugin_settings), do: "plugin-settings-reload"
  defp reload_request_prefix(_kind), do: "plugin-config-reload"

  defp default_watcher_id do
    "plugin-config-watcher-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp file_checksum(path) do
    case File.read(path) do
      {:ok, contents} -> :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
      {:error, _reason} -> nil
    end
  end

  defp options_map(options) when is_map(options), do: options
  defp options_map(options) when is_list(options), do: Map.new(options)

  defp plugin_setting_paths(project_dir, options) do
    options
    |> Map.get(:plugin_setting_paths, Map.get(options, :plugin_settings_paths, []))
    |> List.wrap()
    |> Enum.flat_map(&normalize_plugin_setting_path(&1, project_dir))
    |> Enum.uniq_by(fn source -> {source.plugin_id, source.path} end)
    |> Enum.sort_by(fn source -> {source.plugin_id, source.path} end)
  end

  defp normalize_plugin_setting_path(%{plugin_id: plugin_id, path: path}, project_dir)
       when is_binary(plugin_id) and is_binary(path) do
    [%{kind: :plugin_settings, plugin_id: plugin_id, path: Path.expand(path, project_dir)}]
  end

  defp normalize_plugin_setting_path(%{"plugin_id" => plugin_id, "path" => path}, project_dir)
       when is_binary(plugin_id) and is_binary(path) do
    [%{kind: :plugin_settings, plugin_id: plugin_id, path: Path.expand(path, project_dir)}]
  end

  defp normalize_plugin_setting_path({plugin_id, paths}, project_dir)
       when is_binary(plugin_id) and is_list(paths) do
    Enum.flat_map(paths, &normalize_plugin_setting_path({plugin_id, &1}, project_dir))
  end

  defp normalize_plugin_setting_path({plugin_id, path}, project_dir)
       when is_binary(plugin_id) and is_binary(path) do
    [%{kind: :plugin_settings, plugin_id: plugin_id, path: Path.expand(path, project_dir)}]
  end

  defp normalize_plugin_setting_path(_source, _project_dir), do: []
end
