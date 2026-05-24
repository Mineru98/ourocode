defmodule Ourocode.Config do
  @moduledoc """
  Runtime configuration defaults for ourocode.

  Elixir owns the runtime SSoT and supervision controls, so concurrency knobs
  are exposed through this module instead of being embedded in transport or UI
  code.
  """

  alias Ourocode.Config.CleanupPolicy
  alias Ourocode.Config.Overrides
  alias Ourocode.Config.RawLoader
  alias Ourocode.Config.RuntimeDefaults

  defmodule RawConfig do
    @moduledoc """
    Normalized, unvalidated project configuration loaded from supported files.

    The runtime keeps this shape raw enough for later schema-specific stages to
    validate plugin, MCP, UI, and command sections independently, while still
    normalizing file provenance and key spelling across formats.
    """

    @enforce_keys [:root_dir, :files, :data]
    defstruct root_dir: nil,
              files: [],
              data: %{}

    @type file_entry :: %{
            required(:path) => Path.t(),
            required(:relative_path) => Path.t(),
            required(:format) => :json | :yaml | :toml,
            required(:data) => map()
          }

    @type t :: %__MODULE__{
            root_dir: Path.t(),
            files: [file_entry()],
            data: map()
          }
  end

  @type t :: %{
          required(:parallel_child_count) => pos_integer(),
          required(:repeat_count) => pos_integer(),
          required(:stream_mailbox_capacity) => pos_integer(),
          required(:stream_mailbox_overflow_path) => :drop | :notify,
          required(:stream_mailbox_backpressure_threshold) => pos_integer(),
          required(:stream_mailbox_backpressure_behavior) => :none | :notify | :delay,
          required(:stream_mailbox_backpressure_delay_ms) => pos_integer(),
          required(:allowed_memory_growth_mb) => pos_integer(),
          required(:stale_cleanup_timeout_ms) => pos_integer(),
          required(:operation_timeout_ms) => pos_integer(),
          required(:stream_subscription_cleanup_timeout_ms) => pos_integer(),
          required(:pane_state_retention_ms) => pos_integer(),
          required(:cleanup_policy) => cleanup_policy()
        }

  @type cleanup_policy :: %{
          required(:allowed_memory_growth_mb) => pos_integer(),
          required(:stale_cleanup_timeout_ms) => pos_integer(),
          required(:stream_subscription_cleanup_timeout_ms) => pos_integer(),
          required(:pane_state_retention_ms) => pos_integer()
        }

  @type raw_config_error ::
          {:unsupported_config_format, Path.t()}
          | {:invalid_config_file, Path.t(), term()}
          | {:config_file_must_be_map, Path.t()}
          | {:cannot_read_config_file, Path.t(), term()}

  @type load_error ::
          raw_config_error()
          | {:config_section_must_be_map, String.t(), term()}
          | String.t()

  @doc """
  Returns the default number of child sessions synthetic/runtime workloads may run
  in parallel.
  """
  @spec default_parallel_child_count() :: pos_integer()
  def default_parallel_child_count, do: RuntimeDefaults.default_parallel_child_count()

  @doc """
  Returns the default repeat count for synthetic/runtime workload passes.
  """
  @spec default_repeat_count() :: pos_integer()
  def default_repeat_count, do: RuntimeDefaults.default_repeat_count()

  @doc """
  Returns the default per-stream event mailbox capacity.
  """
  @spec default_stream_mailbox_capacity() :: pos_integer()
  def default_stream_mailbox_capacity, do: RuntimeDefaults.default_stream_mailbox_capacity()

  @doc """
  Returns the default overflow path used when a stream event mailbox is full.
  """
  @spec default_stream_mailbox_overflow_path() :: :drop | :notify
  def default_stream_mailbox_overflow_path,
    do: RuntimeDefaults.default_stream_mailbox_overflow_path()

  @doc """
  Returns the default pending event threshold where stream backpressure begins.
  """
  @spec default_stream_mailbox_backpressure_threshold() :: pos_integer()
  def default_stream_mailbox_backpressure_threshold,
    do: RuntimeDefaults.default_stream_mailbox_backpressure_threshold()

  @doc """
  Returns the default behavior when stream mailbox pressure exceeds threshold.
  """
  @spec default_stream_mailbox_backpressure_behavior() :: :none | :notify | :delay
  def default_stream_mailbox_backpressure_behavior,
    do: RuntimeDefaults.default_stream_mailbox_backpressure_behavior()

  @doc """
  Returns the default producer delay used by delayed stream backpressure.
  """
  @spec default_stream_mailbox_backpressure_delay_ms() :: pos_integer()
  def default_stream_mailbox_backpressure_delay_ms,
    do: RuntimeDefaults.default_stream_mailbox_backpressure_delay_ms()

  @doc """
  Returns the default allowed memory growth in megabytes before cleanup
  monitoring should flag the workload.
  """
  @spec default_allowed_memory_growth_mb() :: pos_integer()
  def default_allowed_memory_growth_mb, do: RuntimeDefaults.default_allowed_memory_growth_mb()

  @doc """
  Returns the default stale cleanup timeout in milliseconds.
  """
  @spec default_stale_cleanup_timeout_ms() :: pos_integer()
  def default_stale_cleanup_timeout_ms, do: RuntimeDefaults.default_stale_cleanup_timeout_ms()

  @doc """
  Returns the default maximum duration for one active stream operation.
  """
  @spec default_operation_timeout_ms() :: pos_integer()
  def default_operation_timeout_ms, do: RuntimeDefaults.default_operation_timeout_ms()

  @doc """
  Returns the default stream subscription cleanup timeout in milliseconds.
  """
  @spec default_stream_subscription_cleanup_timeout_ms() :: pos_integer()
  def default_stream_subscription_cleanup_timeout_ms,
    do: RuntimeDefaults.default_stream_subscription_cleanup_timeout_ms()

  @doc """
  Returns the default pane state retention window in milliseconds.
  """
  @spec default_pane_state_retention_ms() :: pos_integer()
  def default_pane_state_retention_ms, do: RuntimeDefaults.default_pane_state_retention_ms()

  @doc """
  Returns supported project config paths in deterministic discovery order.
  """
  @spec supported_config_candidates() :: [Path.t()]
  def supported_config_candidates, do: RawLoader.supported_config_candidates()

  @doc """
  Finds supported config files under a project directory.

  Discovery is intentionally local to the supplied project root so the
  terminal runtime has an explicit hot-reload boundary and does not accidentally
  ingest parent-directory state.
  """
  @spec discover_config_files(Path.t()) :: [Path.t()]
  def discover_config_files(project_dir), do: RawLoader.discover_config_files(project_dir)

  @doc """
  Loads supported project config files into a normalized raw config object.

  Multiple files are merged in discovery order, with later files overriding
  earlier scalar values and nested maps merging recursively.
  """
  @spec load_raw(Path.t()) :: {:ok, RawConfig.t()} | {:error, raw_config_error()}
  def load_raw(project_dir), do: RawLoader.load(project_dir)

  @doc """
  Parses a single supported config file into one normalized raw file entry.
  """
  @spec parse_config_file(Path.t(), Path.t() | nil) ::
          {:ok, RawConfig.file_entry()} | {:error, raw_config_error()}
  def parse_config_file(path, root_dir \\ nil), do: RawLoader.parse_config_file(path, root_dir)

  @doc """
  Loads runtime configuration for a project directory.

  Missing config files are valid and return the documented runtime defaults.
  When config files exist, only the optional `runtime` and
  `runtime.cleanup_policy` fields that are present are applied; omitted fields
  fall back to the same defaults returned by `defaults/0`. CLI/runtime
  overrides are applied last.
  """
  @spec load(Path.t(), [String.t()] | map()) :: {:ok, t()} | {:error, load_error()}
  def load(project_dir, overrides \\ %{})

  def load(project_dir, args) when is_binary(project_dir) and is_list(args) do
    with {:ok, parsed_overrides} <- parse_overrides(args) do
      load(project_dir, parsed_overrides)
    end
  end

  def load(project_dir, overrides) when is_binary(project_dir) and is_map(overrides) do
    with {:ok, raw_config} <- load_raw(project_dir),
         {:ok, file_overrides} <- RawLoader.runtime_overrides_from_raw(raw_config.data) do
      {:ok, defaults(Map.merge(file_overrides, overrides))}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @doc """
  Returns the default cleanup policy used by runtime cleanup and UI pane retention.
  """
  @spec default_cleanup_policy() :: cleanup_policy()
  def default_cleanup_policy, do: RuntimeDefaults.default_cleanup_policy()

  @doc """
  Returns the configured cleanup policy used by runtime cleanup and UI pane retention.
  """
  @spec cleanup_policy() :: cleanup_policy()
  def cleanup_policy, do: RuntimeDefaults.cleanup_policy()

  @doc """
  Validates a cleanup policy for pane retention and cleanup monitoring.

  Policy values must all be positive integers so cleanup loops cannot be
  disabled accidentally with zero, negative, or non-numeric values.
  """
  @spec validate_cleanup_policy(map()) :: {:ok, cleanup_policy()} | {:error, String.t()}
  def validate_cleanup_policy(policy) when is_map(policy) do
    CleanupPolicy.validate(policy)
  end

  def validate_cleanup_policy(policy) do
    CleanupPolicy.validate(policy)
  end

  @doc """
  Returns the validated runtime defaults.
  """
  @spec defaults() :: t()
  @spec defaults(map()) :: t()
  def defaults(overrides \\ %{})

  def defaults(overrides) when is_map(overrides) do
    RuntimeDefaults.defaults(overrides)
  end

  @doc """
  Parses CLI override arguments and returns the config map they represent.

  Supported inputs use kebab-case flags:

    * `--pane-state-retention-ms 600000`
    * `--stream-mailbox-capacity 1000`
    * `--stream-mailbox-overflow-path=notify`
    * `--stream-mailbox-backpressure-threshold=800`
    * `--stream-mailbox-backpressure-behavior=delay`
    * `--stream-mailbox-backpressure-delay-ms=25`
    * `--stale-cleanup-timeout-ms=45000`
    * `--operation-timeout-ms=120000`
    * `--cleanup-policy.allowed-memory-growth-mb=128`
    * `--cleanup-pane-state-retention-ms=600000`

  Cleanup policy aliases update both top-level compatibility fields and the
  nested `:cleanup_policy` map.
  """
  @spec parse_overrides([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_overrides(args) when is_list(args) do
    Overrides.parse(args)
  end

  @doc """
  Parses CLI override arguments and applies them to configured defaults.
  """
  @spec defaults_from_args([String.t()]) :: {:ok, t()} | {:error, String.t()}
  def defaults_from_args(args) do
    with {:ok, overrides} <- parse_overrides(args) do
      {:ok, defaults(overrides)}
    end
  end
end
