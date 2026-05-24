defmodule Ourocode.Config.RuntimeDefaults do
  @moduledoc false

  alias Ourocode.Config.CleanupPolicy
  alias Ourocode.Config.Overrides

  @app :ourocode
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

  @spec default_parallel_child_count() :: pos_integer()
  def default_parallel_child_count, do: @default_parallel_child_count

  @spec default_repeat_count() :: pos_integer()
  def default_repeat_count, do: @default_repeat_count

  @spec default_stream_mailbox_capacity() :: pos_integer()
  def default_stream_mailbox_capacity, do: @default_stream_mailbox_capacity

  @spec default_stream_mailbox_overflow_path() :: :drop | :notify
  def default_stream_mailbox_overflow_path, do: @default_stream_mailbox_overflow_path

  @spec default_stream_mailbox_backpressure_threshold() :: pos_integer()
  def default_stream_mailbox_backpressure_threshold,
    do: @default_stream_mailbox_backpressure_threshold

  @spec default_stream_mailbox_backpressure_behavior() :: :none | :notify | :delay
  def default_stream_mailbox_backpressure_behavior,
    do: @default_stream_mailbox_backpressure_behavior

  @spec default_stream_mailbox_backpressure_delay_ms() :: pos_integer()
  def default_stream_mailbox_backpressure_delay_ms,
    do: @default_stream_mailbox_backpressure_delay_ms

  @spec default_allowed_memory_growth_mb() :: pos_integer()
  def default_allowed_memory_growth_mb, do: @default_allowed_memory_growth_mb

  @spec default_stale_cleanup_timeout_ms() :: pos_integer()
  def default_stale_cleanup_timeout_ms, do: @default_stale_cleanup_timeout_ms

  @spec default_operation_timeout_ms() :: pos_integer()
  def default_operation_timeout_ms, do: @default_operation_timeout_ms

  @spec default_stream_subscription_cleanup_timeout_ms() :: pos_integer()
  def default_stream_subscription_cleanup_timeout_ms,
    do: @default_stream_subscription_cleanup_timeout_ms

  @spec default_pane_state_retention_ms() :: pos_integer()
  def default_pane_state_retention_ms, do: @default_pane_state_retention_ms

  @spec default_cleanup_policy() :: map()
  def default_cleanup_policy do
    %{
      allowed_memory_growth_mb: default_allowed_memory_growth_mb(),
      stale_cleanup_timeout_ms: default_stale_cleanup_timeout_ms(),
      stream_subscription_cleanup_timeout_ms: default_stream_subscription_cleanup_timeout_ms(),
      pane_state_retention_ms: default_pane_state_retention_ms()
    }
  end

  @spec cleanup_policy() :: map()
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

  @spec defaults(map()) :: map()
  def defaults(overrides \\ %{}) when is_map(overrides) do
    cleanup_policy = cleanup_policy()
    overrides = Overrides.normalize!(overrides)

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

    Overrides.apply(config, overrides)
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
    case CleanupPolicy.validate(policy) do
      {:ok, valid_policy} -> valid_policy
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp configured_stream_mailbox_overflow_path! do
    case Application.fetch_env(@app, :stream_mailbox_overflow_path) do
      :error ->
        default_stream_mailbox_overflow_path()

      {:ok, value} ->
        Overrides.normalize!(%{stream_mailbox_overflow_path: value}).stream_mailbox_overflow_path
    end
  end

  defp configured_stream_mailbox_backpressure_behavior! do
    case Application.fetch_env(@app, :stream_mailbox_backpressure_behavior) do
      :error ->
        default_stream_mailbox_backpressure_behavior()

      {:ok, value} ->
        Overrides.normalize!(%{stream_mailbox_backpressure_behavior: value}).stream_mailbox_backpressure_behavior
    end
  end
end
