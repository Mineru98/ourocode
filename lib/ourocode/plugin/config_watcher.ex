defmodule Ourocode.Plugin.ConfigWatcher do
  @moduledoc """
  Watches plugin configuration sources and emits reload requests.

  The watcher is an Elixir-owned runtime process. It does not reload the
  terminal UI and does not own plugin state; it only detects config source file
  create, modify, and delete transitions and emits data-only reload requests for
  the hot-reload boundary to consume.
  """

  use GenServer

  alias Ourocode.Plugin.ConfigWatcher.Poll
  alias Ourocode.Plugin.ConfigWatcher.SnapshotDiff
  alias Ourocode.Plugin.ConfigWatcher.Sources

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
    Sources.config_paths(project_dir, options)
  end

  @doc """
  Diffs two source snapshots into create, modify, and delete changes.
  """
  @spec diff_snapshots([source_snapshot()], [source_snapshot()]) :: [
          {change(), source_snapshot()}
        ]
  def diff_snapshots(before_snapshots, after_snapshots)
      when is_list(before_snapshots) and is_list(after_snapshots) do
    SnapshotDiff.diff(before_snapshots, after_snapshots)
  end

  @impl GenServer
  def init(options) do
    options = options_map(options)
    project_dir = options |> Map.get(:project_dir, File.cwd!()) |> Path.expand()
    source_paths = source_paths(project_dir, options)
    watch_sources = Sources.watch_sources(project_dir, source_paths, options)

    state = %{
      project_dir: project_dir,
      source_paths: source_paths,
      plugin_setting_paths: Sources.plugin_setting_paths(project_dir, options),
      watch_sources: watch_sources,
      snapshots: Sources.snapshots(watch_sources),
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

  defp poll_sources(state), do: Poll.run(state)

  defp schedule_poll(%{poll_interval_ms: false}), do: :ok
  defp schedule_poll(%{poll_interval_ms: nil}), do: :ok

  defp schedule_poll(%{poll_interval_ms: poll_interval_ms})
       when is_integer(poll_interval_ms) and poll_interval_ms > 0 do
    Process.send_after(self(), :poll, poll_interval_ms)
    :ok
  end

  defp schedule_poll(_state), do: :ok

  defp default_watcher_id do
    "plugin-config-watcher-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp options_map(options) when is_map(options), do: options
  defp options_map(options) when is_list(options), do: Map.new(options)
end
