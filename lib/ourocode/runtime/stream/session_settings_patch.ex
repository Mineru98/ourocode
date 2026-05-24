defmodule Ourocode.Runtime.Stream.SessionSettingsPatch do
  @moduledoc """
  Applies validated session settings patches to stream session state.

  `SessionSettings` validates externally supplied configuration. This module
  bridges that normalized configuration to the live GenServer state fields.
  """

  alias Ourocode.Runtime.SessionSettings

  @settings_key_aliases %{
    "external-ids" => :external_ids,
    "external_ids" => :external_ids,
    "operation-timeout-ms" => :operation_timeout_ms,
    "operation_timeout_ms" => :operation_timeout_ms,
    "stale-cleanup-timeout-ms" => :stale_cleanup_timeout_ms,
    "stale_cleanup_timeout_ms" => :stale_cleanup_timeout_ms,
    "stream-cleanup-action" => :stream_cleanup_action,
    "stream_cleanup_action" => :stream_cleanup_action,
    "stream-cursor" => :stream_cursor,
    "stream_cursor" => :stream_cursor,
    "stream-mailbox-backpressure-behavior" => :stream_mailbox_backpressure_behavior,
    "stream_mailbox_backpressure_behavior" => :stream_mailbox_backpressure_behavior,
    "stream-mailbox-backpressure-delay-ms" => :stream_mailbox_backpressure_delay_ms,
    "stream_mailbox_backpressure_delay_ms" => :stream_mailbox_backpressure_delay_ms,
    "stream-mailbox-backpressure-threshold" => :stream_mailbox_backpressure_threshold,
    "stream_mailbox_backpressure_threshold" => :stream_mailbox_backpressure_threshold,
    "stream-mailbox-capacity" => :stream_mailbox_capacity,
    "stream_mailbox_capacity" => :stream_mailbox_capacity,
    "stream-mailbox-drain-interval-ms" => :stream_mailbox_drain_interval_ms,
    "stream_mailbox_drain_interval_ms" => :stream_mailbox_drain_interval_ms,
    "stream-mailbox-overflow-path" => :stream_mailbox_overflow_path,
    "stream_mailbox_overflow_path" => :stream_mailbox_overflow_path,
    "stream-subscription-cleanup-timeout-ms" => :stream_subscription_cleanup_timeout_ms,
    "stream_subscription_cleanup_timeout_ms" => :stream_subscription_cleanup_timeout_ms
  }

  @doc """
  Applies a map or keyword settings patch to live stream session state.
  """
  @spec apply(map(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def apply(state, settings) when is_map(state) do
    with {:ok, patch} <- normalize_patch(settings),
         {:ok, normalized} <- SessionSettings.normalize(Map.merge(base(state), patch)) do
      {:ok, apply_normalized(state, normalized)}
    end
  end

  @doc """
  Normalizes patch keys to the canonical `SessionSettings` field names.
  """
  @spec normalize_patch(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize_patch(settings) when is_list(settings) do
    if Keyword.keyword?(settings) do
      settings |> Map.new() |> normalize_patch()
    else
      {:error, {:invalid_session_settings, "session settings must be a map or keyword list"}}
    end
  end

  def normalize_patch(settings) when is_map(settings) do
    {:ok, Map.new(settings, fn {key, value} -> {settings_key(key), value} end)}
  end

  def normalize_patch(_settings),
    do: {:error, {:invalid_session_settings, "session settings must be a map or keyword list"}}

  @doc """
  Builds the current settings base from live stream session state.
  """
  @spec base(map()) :: map()
  def base(state) when is_map(state) do
    %{
      runtime_source: state.runtime_source,
      session_id: state.session_id,
      transport: Map.get(state, :transport),
      external_ids: state.external_ids,
      stream_cursor: state.stream_cursor,
      stream_mailbox_capacity: state.stream_mailbox_capacity,
      stream_mailbox_overflow_path: state.stream_mailbox_overflow_path,
      stream_mailbox_backpressure_threshold: state.stream_mailbox_backpressure_threshold,
      stream_mailbox_backpressure_behavior: state.stream_mailbox_backpressure_behavior,
      stream_mailbox_backpressure_delay_ms: state.stream_mailbox_backpressure_delay_ms,
      stale_cleanup_timeout_ms: state.stream_stale_cleanup_timeout_ms,
      operation_timeout_ms: state.stream_operation_timeout_ms,
      stream_subscription_cleanup_timeout_ms: state.stream_subscription_cleanup_timeout_ms,
      stream_mailbox_drain_interval_ms: state.stream_mailbox_drain_interval_ms,
      stream_cleanup_action: state.stream_cleanup_action
    }
  end

  @doc """
  Applies already-normalized settings to live stream session state.
  """
  @spec apply_normalized(map(), keyword()) :: map()
  def apply_normalized(state, normalized) when is_map(state) and is_list(normalized) do
    state
    |> Map.put(:external_ids, Keyword.fetch!(normalized, :external_ids))
    |> Map.put(:stream_cursor, Keyword.fetch!(normalized, :stream_cursor))
    |> Map.put(:stream_mailbox_capacity, Keyword.fetch!(normalized, :stream_mailbox_capacity))
    |> Map.put(
      :stream_mailbox_overflow_path,
      Keyword.fetch!(normalized, :stream_mailbox_overflow_path)
    )
    |> Map.put(
      :stream_mailbox_backpressure_threshold,
      Keyword.fetch!(normalized, :stream_mailbox_backpressure_threshold)
    )
    |> Map.put(
      :stream_mailbox_backpressure_behavior,
      Keyword.fetch!(normalized, :stream_mailbox_backpressure_behavior)
    )
    |> Map.put(
      :stream_mailbox_backpressure_delay_ms,
      Keyword.fetch!(normalized, :stream_mailbox_backpressure_delay_ms)
    )
    |> Map.put(
      :stream_stale_cleanup_timeout_ms,
      Keyword.fetch!(normalized, :stale_cleanup_timeout_ms)
    )
    |> Map.put(:stream_operation_timeout_ms, Keyword.fetch!(normalized, :operation_timeout_ms))
    |> Map.put(
      :stream_subscription_cleanup_timeout_ms,
      Keyword.fetch!(normalized, :stream_subscription_cleanup_timeout_ms)
    )
    |> Map.put(
      :stream_mailbox_drain_interval_ms,
      Keyword.fetch!(normalized, :stream_mailbox_drain_interval_ms)
    )
    |> Map.put(:stream_cleanup_action, Keyword.fetch!(normalized, :stream_cleanup_action))
  end

  defp settings_key(key) when is_atom(key), do: key

  defp settings_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.replace("-", "_")
    |> then(&Map.get(@settings_key_aliases, &1, &1))
  end

  defp settings_key(key), do: key
end
