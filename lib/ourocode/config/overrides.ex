defmodule Ourocode.Config.Overrides do
  @moduledoc """
  CLI/runtime override parsing, normalization, and application for runtime config.
  """

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

  @runtime_fields [
    :parallel_child_count,
    :repeat_count,
    :stream_mailbox_capacity,
    :stream_mailbox_overflow_path,
    :stream_mailbox_backpressure_threshold,
    :stream_mailbox_backpressure_behavior,
    :stream_mailbox_backpressure_delay_ms,
    :operation_timeout_ms
  ]

  @doc """
  Parses CLI override arguments into normalized runtime override keys.
  """
  @spec parse([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse(args) when is_list(args) do
    normalized_args = Enum.map(args, &normalize_arg/1)

    case OptionParser.parse(normalized_args, strict: @override_switches) do
      {parsed, [], []} ->
        {:ok, normalize!(Map.new(parsed))}

      {_parsed, unknown_args, []} ->
        {:error, "unsupported config override arguments: #{Enum.join(unknown_args, ", ")}"}

      {_parsed, _remaining, invalid} ->
        unsupported = Enum.reject(invalid, fn {name, _value} -> known_name?(name) end)

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
  Normalizes already parsed runtime override maps.
  """
  @spec normalize!(map()) :: map()
  def normalize!(overrides) when is_map(overrides) do
    Enum.reduce(overrides, %{}, fn {key, value}, acc ->
      canonical_key = Map.get(@override_aliases, key, key)
      Map.put(acc, canonical_key, normalize_value!(canonical_key, value))
    end)
  end

  @doc """
  Applies normalized overrides to a default runtime config map.
  """
  @spec apply(map(), map()) :: map()
  def apply(config, overrides) when is_map(config) and is_map(overrides) do
    cleanup_policy =
      Map.merge(config.cleanup_policy, Map.take(overrides, Map.keys(config.cleanup_policy)))

    config
    |> Map.merge(Map.take(overrides, @runtime_fields))
    |> Map.merge(cleanup_policy)
    |> Map.put(:cleanup_policy, cleanup_policy)
  end

  defp normalize_value!(:stream_mailbox_overflow_path, value) do
    normalize_stream_mailbox_overflow_path!(value)
  end

  defp normalize_value!(:stream_mailbox_backpressure_behavior, value) do
    normalize_stream_mailbox_backpressure_behavior!(value)
  end

  defp normalize_value!(key, value), do: positive_integer!(key, value)

  defp positive_integer!(_key, value) when is_integer(value) and value > 0, do: value

  defp positive_integer!(key, value) do
    raise ArgumentError,
          "#{key} must be configured as a positive integer, got: #{inspect(value)}"
  end

  defp normalize_stream_mailbox_overflow_path!(path) when path in [:drop, :notify], do: path
  defp normalize_stream_mailbox_overflow_path!("drop"), do: :drop
  defp normalize_stream_mailbox_overflow_path!("notify"), do: :notify

  defp normalize_stream_mailbox_overflow_path!(invalid) do
    raise ArgumentError,
          "stream_mailbox_overflow_path must be configured as drop or notify, " <>
            "got: #{inspect(invalid)}"
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

  defp normalize_arg("--cleanup-policy." <> rest) do
    "--cleanup-policy-" <> rest
  end

  defp normalize_arg(arg), do: arg

  defp known_name?(name) when is_atom(name) do
    Keyword.has_key?(@override_switches, name)
  end

  defp known_name?(name) when is_binary(name) do
    normalized =
      name
      |> String.trim_leading("-")
      |> String.replace("-", "_")

    MapSet.member?(@override_switch_names, normalized)
  end

  defp known_name?(_name), do: false

  defp format_invalid_args(args) do
    args
    |> Enum.map(fn {name, value} -> "#{name}=#{inspect(value)}" end)
    |> Enum.join(", ")
  end
end
