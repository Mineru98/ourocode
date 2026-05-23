defmodule Ourocode.Config do
  @moduledoc """
  Runtime configuration defaults for ourocode.

  Elixir owns the runtime SSoT and supervision controls, so concurrency knobs
  are exposed through this module instead of being embedded in transport or UI
  code.
  """

  alias Ourocode.Json

  @default_parallel_child_count 3
  @default_repeat_count 1
  @default_allowed_memory_growth_mb 64
  @default_stale_cleanup_timeout_ms 30_000
  @default_operation_timeout_ms 120_000
  @default_stream_subscription_cleanup_timeout_ms 10_000
  @default_pane_state_retention_ms 300_000
  @default_stream_mailbox_capacity 1_000
  @default_stream_mailbox_overflow_path :drop
  @default_stream_mailbox_backpressure_threshold 800
  @default_stream_mailbox_backpressure_behavior :notify
  @default_stream_mailbox_backpressure_delay_ms 10
  @app :ourocode
  @supported_config_candidates [
    "ourocode.json",
    "ourocode.yaml",
    "ourocode.yml",
    "ourocode.toml",
    ".ourocode.json",
    ".ourocode.yaml",
    ".ourocode.yml",
    ".ourocode.toml",
    Path.join([".ourocode", "config.json"]),
    Path.join([".ourocode", "config.yaml"]),
    Path.join([".ourocode", "config.yml"]),
    Path.join([".ourocode", "config.toml"])
  ]
  @cleanup_policy_keys [
    :allowed_memory_growth_mb,
    :stale_cleanup_timeout_ms,
    :stream_subscription_cleanup_timeout_ms,
    :pane_state_retention_ms
  ]
  @override_switches [
    parallel_child_count: :integer,
    repeat_count: :integer,
    stream_mailbox_capacity: :integer,
    stream_mailbox_overflow_path: :string,
    stream_mailbox_backpressure_threshold: :integer,
    stream_mailbox_backpressure_behavior: :string,
    stream_mailbox_backpressure_delay_ms: :integer,
    allowed_memory_growth_mb: :integer,
    stale_cleanup_timeout_ms: :integer,
    operation_timeout_ms: :integer,
    stream_subscription_cleanup_timeout_ms: :integer,
    pane_state_retention_ms: :integer,
    cleanup_allowed_memory_growth_mb: :integer,
    cleanup_stale_cleanup_timeout_ms: :integer,
    cleanup_stream_subscription_cleanup_timeout_ms: :integer,
    cleanup_pane_state_retention_ms: :integer,
    cleanup_policy_allowed_memory_growth_mb: :integer,
    cleanup_policy_stale_cleanup_timeout_ms: :integer,
    cleanup_policy_stream_subscription_cleanup_timeout_ms: :integer,
    cleanup_policy_pane_state_retention_ms: :integer
  ]
  @override_switch_names MapSet.new(Keyword.keys(@override_switches), &Atom.to_string/1)

  @override_aliases %{
    cleanup_allowed_memory_growth_mb: :allowed_memory_growth_mb,
    cleanup_stale_cleanup_timeout_ms: :stale_cleanup_timeout_ms,
    cleanup_stream_subscription_cleanup_timeout_ms: :stream_subscription_cleanup_timeout_ms,
    cleanup_pane_state_retention_ms: :pane_state_retention_ms,
    cleanup_policy_allowed_memory_growth_mb: :allowed_memory_growth_mb,
    cleanup_policy_stale_cleanup_timeout_ms: :stale_cleanup_timeout_ms,
    cleanup_policy_stream_subscription_cleanup_timeout_ms:
      :stream_subscription_cleanup_timeout_ms,
    cleanup_policy_pane_state_retention_ms: :pane_state_retention_ms
  }
  @runtime_override_keys [
    :parallel_child_count,
    :repeat_count,
    :stream_mailbox_capacity,
    :stream_mailbox_overflow_path,
    :stream_mailbox_backpressure_threshold,
    :stream_mailbox_backpressure_behavior,
    :stream_mailbox_backpressure_delay_ms,
    :allowed_memory_growth_mb,
    :stale_cleanup_timeout_ms,
    :operation_timeout_ms,
    :stream_subscription_cleanup_timeout_ms,
    :pane_state_retention_ms
  ]
  @runtime_override_key_names Map.new(@runtime_override_keys, &{Atom.to_string(&1), &1})

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
  def default_parallel_child_count, do: @default_parallel_child_count

  @doc """
  Returns the default repeat count for synthetic/runtime workload passes.
  """
  @spec default_repeat_count() :: pos_integer()
  def default_repeat_count, do: @default_repeat_count

  @doc """
  Returns the default per-stream event mailbox capacity.
  """
  @spec default_stream_mailbox_capacity() :: pos_integer()
  def default_stream_mailbox_capacity, do: @default_stream_mailbox_capacity

  @doc """
  Returns the default overflow path used when a stream event mailbox is full.
  """
  @spec default_stream_mailbox_overflow_path() :: :drop | :notify
  def default_stream_mailbox_overflow_path, do: @default_stream_mailbox_overflow_path

  @doc """
  Returns the default pending event threshold where stream backpressure begins.
  """
  @spec default_stream_mailbox_backpressure_threshold() :: pos_integer()
  def default_stream_mailbox_backpressure_threshold,
    do: @default_stream_mailbox_backpressure_threshold

  @doc """
  Returns the default behavior when stream mailbox pressure exceeds threshold.
  """
  @spec default_stream_mailbox_backpressure_behavior() :: :none | :notify | :delay
  def default_stream_mailbox_backpressure_behavior,
    do: @default_stream_mailbox_backpressure_behavior

  @doc """
  Returns the default producer delay used by delayed stream backpressure.
  """
  @spec default_stream_mailbox_backpressure_delay_ms() :: pos_integer()
  def default_stream_mailbox_backpressure_delay_ms,
    do: @default_stream_mailbox_backpressure_delay_ms

  @doc """
  Returns the default allowed memory growth in megabytes before cleanup
  monitoring should flag the workload.
  """
  @spec default_allowed_memory_growth_mb() :: pos_integer()
  def default_allowed_memory_growth_mb, do: @default_allowed_memory_growth_mb

  @doc """
  Returns the default stale cleanup timeout in milliseconds.
  """
  @spec default_stale_cleanup_timeout_ms() :: pos_integer()
  def default_stale_cleanup_timeout_ms, do: @default_stale_cleanup_timeout_ms

  @doc """
  Returns the default maximum duration for one active stream operation.
  """
  @spec default_operation_timeout_ms() :: pos_integer()
  def default_operation_timeout_ms, do: @default_operation_timeout_ms

  @doc """
  Returns the default stream subscription cleanup timeout in milliseconds.
  """
  @spec default_stream_subscription_cleanup_timeout_ms() :: pos_integer()
  def default_stream_subscription_cleanup_timeout_ms,
    do: @default_stream_subscription_cleanup_timeout_ms

  @doc """
  Returns the default pane state retention window in milliseconds.
  """
  @spec default_pane_state_retention_ms() :: pos_integer()
  def default_pane_state_retention_ms, do: @default_pane_state_retention_ms

  @doc """
  Returns supported project config paths in deterministic discovery order.
  """
  @spec supported_config_candidates() :: [Path.t()]
  def supported_config_candidates, do: @supported_config_candidates

  @doc """
  Finds supported config files under a project directory.

  Discovery is intentionally local to the supplied project root so the
  terminal runtime has an explicit hot-reload boundary and does not accidentally
  ingest parent-directory state.
  """
  @spec discover_config_files(Path.t()) :: [Path.t()]
  def discover_config_files(project_dir) when is_binary(project_dir) do
    root_dir = Path.expand(project_dir)

    @supported_config_candidates
    |> Enum.map(&Path.join(root_dir, &1))
    |> Enum.filter(&File.regular?/1)
  end

  @doc """
  Loads supported project config files into a normalized raw config object.

  Multiple files are merged in discovery order, with later files overriding
  earlier scalar values and nested maps merging recursively.
  """
  @spec load_raw(Path.t()) :: {:ok, RawConfig.t()} | {:error, raw_config_error()}
  def load_raw(project_dir) when is_binary(project_dir) do
    root_dir = Path.expand(project_dir)

    Enum.reduce_while(discover_config_files(root_dir), {:ok, []}, fn path, {:ok, entries} ->
      case parse_config_file(path, root_dir) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} ->
        files = Enum.reverse(entries)
        data = Enum.reduce(files, %{}, fn entry, acc -> deep_merge(acc, entry.data) end)
        {:ok, %RawConfig{root_dir: root_dir, files: files, data: data}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses a single supported config file into one normalized raw file entry.
  """
  @spec parse_config_file(Path.t(), Path.t() | nil) ::
          {:ok, RawConfig.file_entry()} | {:error, raw_config_error()}
  def parse_config_file(path, root_dir \\ nil) when is_binary(path) do
    expanded_path = Path.expand(path)

    root_dir =
      if is_binary(root_dir), do: Path.expand(root_dir), else: Path.dirname(expanded_path)

    with {:ok, format} <- config_format(expanded_path),
         {:ok, contents} <- read_config_file(expanded_path),
         {:ok, data} <- parse_config_contents(contents, format, expanded_path),
         {:ok, map} <- require_config_map(data, expanded_path) do
      {:ok,
       %{
         path: expanded_path,
         relative_path: Path.relative_to(expanded_path, root_dir),
         format: format,
         data: normalize_raw_config(map)
       }}
    end
  end

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
         {:ok, file_overrides} <- runtime_overrides_from_raw(raw_config.data) do
      {:ok, defaults(Map.merge(file_overrides, overrides))}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @doc """
  Returns the default cleanup policy used by runtime cleanup and UI pane retention.
  """
  @spec default_cleanup_policy() :: cleanup_policy()
  def default_cleanup_policy do
    %{
      allowed_memory_growth_mb: default_allowed_memory_growth_mb(),
      stale_cleanup_timeout_ms: default_stale_cleanup_timeout_ms(),
      stream_subscription_cleanup_timeout_ms: default_stream_subscription_cleanup_timeout_ms(),
      pane_state_retention_ms: default_pane_state_retention_ms()
    }
  end

  @doc """
  Returns the configured cleanup policy used by runtime cleanup and UI pane retention.
  """
  @spec cleanup_policy() :: cleanup_policy()
  def cleanup_policy do
    case Application.fetch_env(@app, :cleanup_policy) do
      :error ->
        default_cleanup_policy()
        |> Map.new(fn {key, fallback} -> {key, configured_positive_integer!(key, fallback)} end)
        |> validate_cleanup_policy!()

      {:ok, policy} ->
        validate_cleanup_policy!(policy)
    end
  end

  @doc """
  Validates a cleanup policy for pane retention and cleanup monitoring.

  Policy values must all be positive integers so cleanup loops cannot be
  disabled accidentally with zero, negative, or non-numeric values.
  """
  @spec validate_cleanup_policy(map()) :: {:ok, cleanup_policy()} | {:error, String.t()}
  def validate_cleanup_policy(policy) when is_map(policy) do
    normalized = normalize_cleanup_policy_keys(policy)

    with :ok <- reject_unknown_cleanup_policy_keys(normalized),
         :ok <- require_cleanup_policy_keys(normalized),
         :ok <- validate_cleanup_policy_values(normalized) do
      {:ok, Map.take(normalized, @cleanup_policy_keys)}
    end
  end

  def validate_cleanup_policy(policy) do
    {:error, "cleanup_policy must be configured as a map, got: #{inspect(policy)}"}
  end

  @doc """
  Returns the validated runtime defaults.
  """
  @spec defaults() :: t()
  @spec defaults(map()) :: t()
  def defaults(overrides \\ %{})

  def defaults(overrides) when is_map(overrides) do
    cleanup_policy = cleanup_policy()
    overrides = normalize_override_map!(overrides)

    config = %{
      parallel_child_count:
        configured_positive_integer!(:parallel_child_count, default_parallel_child_count()),
      repeat_count: configured_positive_integer!(:repeat_count, default_repeat_count()),
      stream_mailbox_capacity:
        configured_positive_integer!(:stream_mailbox_capacity, default_stream_mailbox_capacity()),
      stream_mailbox_overflow_path: configured_stream_mailbox_overflow_path!(),
      stream_mailbox_backpressure_threshold:
        configured_positive_integer!(
          :stream_mailbox_backpressure_threshold,
          default_stream_mailbox_backpressure_threshold()
        ),
      stream_mailbox_backpressure_behavior: configured_stream_mailbox_backpressure_behavior!(),
      stream_mailbox_backpressure_delay_ms:
        configured_positive_integer!(
          :stream_mailbox_backpressure_delay_ms,
          default_stream_mailbox_backpressure_delay_ms()
        ),
      allowed_memory_growth_mb: cleanup_policy.allowed_memory_growth_mb,
      stale_cleanup_timeout_ms: cleanup_policy.stale_cleanup_timeout_ms,
      operation_timeout_ms:
        configured_positive_integer!(:operation_timeout_ms, default_operation_timeout_ms()),
      stream_subscription_cleanup_timeout_ms:
        cleanup_policy.stream_subscription_cleanup_timeout_ms,
      pane_state_retention_ms: cleanup_policy.pane_state_retention_ms,
      cleanup_policy: cleanup_policy
    }

    apply_overrides(config, overrides)
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
    normalized_args = Enum.map(args, &normalize_override_arg/1)

    case OptionParser.parse(normalized_args, strict: @override_switches) do
      {parsed, [], []} ->
        {:ok, normalize_override_map!(Map.new(parsed))}

      {_parsed, unknown_args, []} ->
        {:error, "unsupported config override arguments: #{Enum.join(unknown_args, ", ")}"}

      {_parsed, _remaining, invalid} ->
        unsupported = Enum.reject(invalid, fn {name, _value} -> known_override_name?(name) end)

        if unsupported == [] do
          {:error, "invalid config override arguments: #{format_invalid_args(invalid)}"}
        else
          {:error, "unsupported config override arguments: #{format_invalid_args(unsupported)}"}
        end
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
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

  defp config_format(path) do
    case path |> Path.basename() |> String.downcase() do
      name when name in ["ourocode.json", ".ourocode.json", "config.json"] ->
        {:ok, :json}

      name when name in ["ourocode.yaml", "ourocode.yml", ".ourocode.yaml", ".ourocode.yml"] ->
        {:ok, :yaml}

      name when name in ["config.yaml", "config.yml"] ->
        {:ok, :yaml}

      name when name in ["ourocode.toml", ".ourocode.toml", "config.toml"] ->
        {:ok, :toml}

      _name ->
        {:error, {:unsupported_config_format, path}}
    end
  end

  defp read_config_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:cannot_read_config_file, path, reason}}
    end
  end

  defp parse_config_contents(contents, :json, path) do
    case Json.decode(contents) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:invalid_config_file, path, reason}}
    end
  end

  defp parse_config_contents(contents, :yaml, path) do
    parse_simple_yaml(contents)
  rescue
    error -> {:error, {:invalid_config_file, path, Exception.message(error)}}
  catch
    {:invalid_yaml, reason} -> {:error, {:invalid_config_file, path, reason}}
  end

  defp parse_config_contents(contents, :toml, path) do
    parse_simple_toml(contents)
  rescue
    error -> {:error, {:invalid_config_file, path, Exception.message(error)}}
  catch
    {:invalid_toml, reason} -> {:error, {:invalid_config_file, path, reason}}
  end

  defp require_config_map(data, _path) when is_map(data), do: {:ok, data}
  defp require_config_map(_data, path), do: {:error, {:config_file_must_be_map, path}}

  defp runtime_overrides_from_raw(data) when is_map(data) do
    with {:ok, runtime} <- optional_config_section(data, "runtime"),
         {:ok, cleanup_policy} <- optional_config_section(runtime, "cleanup_policy") do
      runtime
      |> Map.drop(["cleanup_policy"])
      |> override_keys_from_string_map()
      |> Map.merge(override_keys_from_string_map(cleanup_policy))
      |> then(&{:ok, &1})
    end
  end

  defp optional_config_section(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      :error -> {:ok, %{}}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, invalid} -> {:error, {:config_section_must_be_map, key, invalid}}
    end
  end

  defp override_keys_from_string_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      case runtime_override_key(key) do
        {:ok, override_key} -> Map.put(acc, override_key, value)
        :error -> acc
      end
    end)
  end

  defp runtime_override_key(key) when is_binary(key) do
    key
    |> String.replace("-", "_")
    |> then(&Map.fetch(@runtime_override_key_names, &1))
  end

  defp runtime_override_key(key) when key in @runtime_override_keys, do: {:ok, key}
  defp runtime_override_key(_key), do: :error

  defp normalize_raw_config(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} ->
      {normalize_raw_key(key), normalize_raw_config(nested_value)}
    end)
    |> Map.new()
  end

  defp normalize_raw_config(value) when is_list(value),
    do: Enum.map(value, &normalize_raw_config/1)

  defp normalize_raw_config(value), do: value

  defp normalize_raw_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> normalize_raw_key()

  defp normalize_raw_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.replace("-", "_")
  end

  defp normalize_raw_key(key), do: key |> to_string() |> normalize_raw_key()

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp parse_simple_yaml(contents) do
    lines =
      contents
      |> String.split("\n")
      |> Enum.map(&strip_config_comment/1)
      |> Enum.reject(&(String.trim(&1) == ""))

    parse_yaml_block(lines, 0)
    |> case do
      {map, []} -> {:ok, map}
      {_map, [line | _rest]} -> throw({:invalid_yaml, "unexpected line: #{String.trim(line)}"})
    end
  end

  defp parse_yaml_block([], _indent), do: {%{}, []}

  defp parse_yaml_block(lines, indent) do
    Enum.reduce_while(lines, {%{}, lines}, fn _line, {acc, remaining} ->
      case remaining do
        [] ->
          {:halt, {acc, []}}

        [line | rest] ->
          line_indent = indentation(line)

          cond do
            line_indent < indent ->
              {:halt, {acc, remaining}}

            line_indent > indent ->
              throw({:invalid_yaml, "unexpected indentation: #{String.trim(line)}"})

            true ->
              {key, value} = parse_yaml_pair(String.trim(line))

              if value == "" do
                {nested, nested_rest} = parse_yaml_nested(rest, indent + 2)
                {:cont, {Map.put(acc, key, nested), nested_rest}}
              else
                {:cont, {Map.put(acc, key, parse_config_scalar(value)), rest}}
              end
          end
      end
    end)
  end

  defp parse_yaml_nested([line | _rest] = lines, indent) do
    if indentation(line) == indent and line |> String.trim() |> String.starts_with?("- ") do
      parse_yaml_list(lines, indent)
    else
      parse_yaml_block(lines, indent)
    end
  end

  defp parse_yaml_nested([], _indent), do: {%{}, []}

  defp parse_yaml_list(lines, indent) do
    parse_yaml_list(lines, indent, [])
  end

  defp parse_yaml_list([], _indent, acc), do: {Enum.reverse(acc), []}

  defp parse_yaml_list([line | rest] = remaining, indent, acc) do
    line_indent = indentation(line)
    trimmed = String.trim(line)

    cond do
      line_indent < indent ->
        {Enum.reverse(acc), remaining}

      line_indent > indent ->
        throw({:invalid_yaml, "unexpected list indentation: #{trimmed}"})

      not String.starts_with?(trimmed, "- ") ->
        {Enum.reverse(acc), remaining}

      true ->
        item_source = trimmed |> String.trim_leading("- ") |> String.trim()
        {item, after_item} = parse_yaml_list_item(item_source, rest, indent)
        parse_yaml_list(after_item, indent, [item | acc])
    end
  end

  defp parse_yaml_list_item("", rest, indent) do
    parse_yaml_nested(rest, indent + 2)
  end

  defp parse_yaml_list_item(item_source, rest, indent) do
    item =
      if String.contains?(item_source, ":") do
        {key, value} = parse_yaml_pair(item_source)

        if value == "" do
          {nested, nested_rest} = parse_yaml_nested(rest, indent + 2)
          {%{key => nested}, nested_rest}
        else
          {%{key => parse_config_scalar(value)}, rest}
        end
      else
        {parse_config_scalar(item_source), rest}
      end

    merge_yaml_list_item_continuation(item, indent)
  end

  defp merge_yaml_list_item_continuation({item, [line | _rest] = rest}, indent)
       when is_map(item) do
    if indentation(line) > indent do
      {continuation, remaining} = parse_yaml_block(rest, indent + 2)
      {Map.merge(item, continuation), remaining}
    else
      {item, rest}
    end
  end

  defp merge_yaml_list_item_continuation({item, rest}, _indent), do: {item, rest}

  defp parse_yaml_pair(line) do
    case String.split(line, ":", parts: 2) do
      [key, value] when key != "" -> {String.trim(key), String.trim(value)}
      _other -> throw({:invalid_yaml, "expected key: value, got: #{line}"})
    end
  end

  defp parse_simple_toml(contents) do
    contents
    |> String.split("\n")
    |> Enum.map(&strip_config_comment/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce({%{}, []}, fn line, {acc, section} ->
      trimmed = String.trim(line)

      cond do
        String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]") ->
          section =
            trimmed
            |> String.trim_leading("[")
            |> String.trim_trailing("]")
            |> String.split(".", trim: true)
            |> Enum.map(&String.trim/1)

          if section == [] do
            throw({:invalid_toml, "empty section header"})
          end

          {acc, section}

        true ->
          case String.split(trimmed, "=", parts: 2) do
            [key, value] ->
              path = section ++ [String.trim(key)]
              {put_nested(acc, path, parse_config_scalar(String.trim(value))), section}

            _other ->
              throw({:invalid_toml, "expected key = value, got: #{trimmed}"})
          end
      end
    end)
    |> elem(0)
    |> then(&{:ok, &1})
  end

  defp put_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_nested(map, [key | rest], value) do
    nested = Map.get(map, key, %{})

    if is_map(nested) do
      Map.put(map, key, put_nested(nested, rest, value))
    else
      throw({:invalid_toml, "cannot assign nested value under scalar key: #{key}"})
    end
  end

  defp strip_config_comment(line) do
    line
    |> String.split("#", parts: 2)
    |> hd()
  end

  defp indentation(line),
    do: line |> String.length() |> Kernel.-(String.length(String.trim_leading(line)))

  defp parse_config_scalar(""), do: ""
  defp parse_config_scalar("true"), do: true
  defp parse_config_scalar("false"), do: false
  defp parse_config_scalar("null"), do: nil
  defp parse_config_scalar("nil"), do: nil

  defp parse_config_scalar("[" <> _rest = value) do
    if String.ends_with?(value, "]") do
      value
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> split_scalar_list()
      |> Enum.map(&parse_config_scalar/1)
    else
      value
    end
  end

  defp parse_config_scalar(value) do
    cond do
      quoted_string?(value) ->
        value
        |> String.slice(1..-2//1)
        |> String.replace("\\\"", "\"")

      match?({_integer, ""}, Integer.parse(value)) ->
        {integer, ""} = Integer.parse(value)
        integer

      match?({_float, ""}, Float.parse(value)) and String.contains?(value, ".") ->
        {float, ""} = Float.parse(value)
        float

      true ->
        value
    end
  end

  defp split_scalar_list(""), do: []

  defp split_scalar_list(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp quoted_string?(value) do
    (String.starts_with?(value, "\"") and String.ends_with?(value, "\"")) or
      (String.starts_with?(value, "'") and String.ends_with?(value, "'"))
  end

  defp configured_positive_integer!(key, fallback) do
    case Application.fetch_env(@app, key) do
      :error ->
        fallback

      {:ok, value} when is_integer(value) and value > 0 ->
        value

      {:ok, invalid} ->
        raise ArgumentError,
              "#{key} must be configured as a positive integer, got: #{inspect(invalid)}"
    end
  end

  defp validate_cleanup_policy!(policy) do
    case validate_cleanup_policy(policy) do
      {:ok, valid_policy} -> valid_policy
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp apply_overrides(config, overrides) do
    cleanup_policy =
      Map.merge(config.cleanup_policy, Map.take(overrides, Map.keys(config.cleanup_policy)))

    config
    |> Map.merge(
      Map.take(overrides, [
        :parallel_child_count,
        :repeat_count,
        :stream_mailbox_capacity,
        :stream_mailbox_overflow_path,
        :stream_mailbox_backpressure_threshold,
        :stream_mailbox_backpressure_behavior,
        :stream_mailbox_backpressure_delay_ms,
        :operation_timeout_ms
      ])
    )
    |> Map.merge(cleanup_policy)
    |> Map.put(:cleanup_policy, cleanup_policy)
  end

  defp normalize_override_map!(overrides) do
    Enum.reduce(overrides, %{}, fn {key, value}, acc ->
      canonical_key = Map.get(@override_aliases, key, key)
      Map.put(acc, canonical_key, normalize_override_value!(canonical_key, value))
    end)
  end

  defp normalize_override_value!(:stream_mailbox_overflow_path, value) do
    normalize_stream_mailbox_overflow_path!(value)
  end

  defp normalize_override_value!(:stream_mailbox_backpressure_behavior, value) do
    normalize_stream_mailbox_backpressure_behavior!(value)
  end

  defp normalize_override_value!(key, value), do: positive_integer!(key, value)

  defp positive_integer!(_key, value) when is_integer(value) and value > 0, do: value

  defp positive_integer!(key, value) do
    raise ArgumentError,
          "#{key} must be configured as a positive integer, got: #{inspect(value)}"
  end

  defp configured_stream_mailbox_overflow_path! do
    case Application.fetch_env(@app, :stream_mailbox_overflow_path) do
      :error -> default_stream_mailbox_overflow_path()
      {:ok, value} -> normalize_stream_mailbox_overflow_path!(value)
    end
  end

  defp normalize_stream_mailbox_overflow_path!(path) when path in [:drop, :notify], do: path
  defp normalize_stream_mailbox_overflow_path!("drop"), do: :drop
  defp normalize_stream_mailbox_overflow_path!("notify"), do: :notify

  defp normalize_stream_mailbox_overflow_path!(invalid) do
    raise ArgumentError,
          "stream_mailbox_overflow_path must be configured as drop or notify, " <>
            "got: #{inspect(invalid)}"
  end

  defp configured_stream_mailbox_backpressure_behavior! do
    case Application.fetch_env(@app, :stream_mailbox_backpressure_behavior) do
      :error -> default_stream_mailbox_backpressure_behavior()
      {:ok, value} -> normalize_stream_mailbox_backpressure_behavior!(value)
    end
  end

  defp normalize_stream_mailbox_backpressure_behavior!(behavior)
       when behavior in [:none, :notify, :delay],
       do: behavior

  defp normalize_stream_mailbox_backpressure_behavior!("none"), do: :none
  defp normalize_stream_mailbox_backpressure_behavior!("notify"), do: :notify
  defp normalize_stream_mailbox_backpressure_behavior!("delay"), do: :delay

  defp normalize_stream_mailbox_backpressure_behavior!(invalid) do
    raise ArgumentError,
          "stream_mailbox_backpressure_behavior must be configured as none, notify, or delay, " <>
            "got: #{inspect(invalid)}"
  end

  defp normalize_cleanup_policy_keys(policy) do
    Map.new(policy, fn
      {key, value} when is_binary(key) ->
        normalized_key =
          key
          |> String.replace("-", "_")
          |> String.to_existing_atom()

        {normalized_key, value}

      {key, value} ->
        {key, value}
    end)
  rescue
    ArgumentError -> policy
  end

  defp reject_unknown_cleanup_policy_keys(policy) do
    unknown_keys = Map.keys(policy) -- @cleanup_policy_keys

    if unknown_keys == [] do
      :ok
    else
      {:error, "cleanup_policy contains unsupported keys: #{inspect(unknown_keys)}"}
    end
  end

  defp require_cleanup_policy_keys(policy) do
    missing_keys = @cleanup_policy_keys -- Map.keys(policy)

    if missing_keys == [] do
      :ok
    else
      {:error, "cleanup_policy is missing required keys: #{inspect(missing_keys)}"}
    end
  end

  defp validate_cleanup_policy_values(policy) do
    Enum.reduce_while(@cleanup_policy_keys, :ok, fn key, :ok ->
      case Map.fetch!(policy, key) do
        value when is_integer(value) and value > 0 ->
          {:cont, :ok}

        invalid ->
          message =
            "cleanup_policy.#{key} must be configured as a positive integer, " <>
              "got: #{inspect(invalid)}"

          {:halt, {:error, message}}
      end
    end)
  end

  defp normalize_override_arg("--cleanup-policy." <> rest) do
    "--cleanup-policy-" <> rest
  end

  defp normalize_override_arg(arg), do: arg

  defp known_override_name?(name) when is_atom(name) do
    Keyword.has_key?(@override_switches, name)
  end

  defp known_override_name?(name) when is_binary(name) do
    normalized =
      name
      |> String.trim_leading("-")
      |> String.replace("-", "_")

    MapSet.member?(@override_switch_names, normalized)
  end

  defp known_override_name?(_name), do: false

  defp format_invalid_args(args) do
    args
    |> Enum.map(fn {name, value} -> "#{name}=#{inspect(value)}" end)
    |> Enum.join(", ")
  end
end
