defmodule Ourocode.Runtime.SessionSettings do
  @moduledoc """
  Normalizes and validates configuration for supervised runtime session streams.

  The runtime session process is the Elixir-owned SSoT for session cursor and
  stream state. This module keeps externally supplied session configuration out
  of that process until identifiers, MCP transport names, mailbox controls, and
  lifecycle settings have been checked with actionable errors.
  """

  alias Ourocode.Config
  alias Ourocode.Runtime.SessionSettings.Fields

  @type normalized :: keyword()
  @type validation_error :: {:invalid_session_settings, String.t()}

  @doc """
  Normalizes a map or keyword list into validated session stream options.
  """
  @spec normalize(map() | keyword()) :: {:ok, normalized()} | {:error, validation_error()}
  def normalize(settings) when is_list(settings) do
    if Keyword.keyword?(settings) do
      settings |> Map.new() |> normalize()
    else
      invalid("session settings must be a map or keyword list")
    end
  end

  def normalize(settings) when is_map(settings) do
    settings = Fields.normalize_keys(settings)
    defaults = Config.defaults()

    with {:ok, runtime_source} <-
           Fields.non_empty_string(settings, :runtime_source, "synthetic", "runtime_source"),
         {:ok, session_id} <-
           Fields.optional_non_empty_string(settings, :session_id, "session_id"),
         {:ok, transport} <- Fields.transport(settings),
         {:ok, external_ids} <- Fields.external_ids(settings),
         {:ok, stream_cursor} <- Fields.map_field(settings, :stream_cursor, %{}, "stream_cursor"),
         {:ok, mailbox_capacity} <-
           Fields.positive_integer(
             settings,
             :stream_mailbox_capacity,
             defaults.stream_mailbox_capacity,
             "stream_mailbox_capacity"
           ),
         {:ok, overflow_path} <-
           Fields.overflow_path(settings, defaults.stream_mailbox_overflow_path),
         {:ok, backpressure_threshold} <-
           Fields.positive_integer(
             settings,
             :stream_mailbox_backpressure_threshold,
             defaults.stream_mailbox_backpressure_threshold,
             "stream_mailbox_backpressure_threshold"
           ),
         {:ok, backpressure_behavior} <-
           Fields.backpressure_behavior(settings, defaults.stream_mailbox_backpressure_behavior),
         {:ok, backpressure_delay_ms} <-
           Fields.positive_integer(
             settings,
             :stream_mailbox_backpressure_delay_ms,
             defaults.stream_mailbox_backpressure_delay_ms,
             "stream_mailbox_backpressure_delay_ms"
           ),
         {:ok, stale_cleanup_timeout_ms} <-
           Fields.positive_integer(
             settings,
             :stale_cleanup_timeout_ms,
             defaults.stale_cleanup_timeout_ms,
             "stale_cleanup_timeout_ms"
           ),
         {:ok, operation_timeout_ms} <-
           Fields.positive_integer(
             settings,
             :operation_timeout_ms,
             defaults.operation_timeout_ms,
             "operation_timeout_ms"
           ),
         {:ok, stream_subscription_cleanup_timeout_ms} <-
           Fields.positive_integer(
             settings,
             :stream_subscription_cleanup_timeout_ms,
             defaults.stream_subscription_cleanup_timeout_ms,
             "stream_subscription_cleanup_timeout_ms"
           ),
         {:ok, stream_mailbox_drain_interval_ms} <- Fields.drain_interval(settings),
         {:ok, stream_cleanup_action} <- Fields.cleanup_action(settings),
         :ok <- Fields.validate_mailbox_bounds(mailbox_capacity, backpressure_threshold) do
      normalized =
        [
          runtime_source: runtime_source,
          external_ids: external_ids,
          stream_cursor: stream_cursor,
          stream_mailbox_capacity: mailbox_capacity,
          stream_mailbox_overflow_path: overflow_path,
          stream_mailbox_backpressure_threshold: backpressure_threshold,
          stream_mailbox_backpressure_behavior: backpressure_behavior,
          stream_mailbox_backpressure_delay_ms: backpressure_delay_ms,
          stale_cleanup_timeout_ms: stale_cleanup_timeout_ms,
          operation_timeout_ms: operation_timeout_ms,
          stream_subscription_cleanup_timeout_ms: stream_subscription_cleanup_timeout_ms,
          stream_mailbox_drain_interval_ms: stream_mailbox_drain_interval_ms,
          stream_cleanup_action: stream_cleanup_action
        ]
        |> maybe_put(:session_id, session_id)
        |> maybe_put(:transport, transport)
        |> Fields.append_passthrough(settings)

      {:ok, normalized}
    end
  end

  def normalize(_settings), do: invalid("session settings must be a map or keyword list")

  @doc """
  Validates session settings without returning normalized values.
  """
  @spec validate(map() | keyword()) :: :ok | {:error, validation_error()}
  def validate(settings) do
    case normalize(settings) do
      {:ok, _normalized} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp invalid(message), do: {:error, {:invalid_session_settings, message}}
end
