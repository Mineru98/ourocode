defmodule Ourocode.Runtime.SessionSettings.Fields do
  @moduledoc """
  Field normalization and validation helpers for runtime session settings.
  """

  @supported_transports [:stdio, :sse, :streamable_http]
  @supported_overflow_paths [:drop, :notify]
  @supported_backpressure_behaviors [:none, :notify, :delay]
  @supported_cleanup_actions [:stop, :mark_stale]

  @session_fields [
    :runtime_source,
    :session_id,
    :transport,
    :external_ids,
    :stream_cursor,
    :stream_mailbox_capacity,
    :stream_mailbox_overflow_path,
    :stream_mailbox_backpressure_threshold,
    :stream_mailbox_backpressure_behavior,
    :stream_mailbox_backpressure_delay_ms,
    :stale_cleanup_timeout_ms,
    :operation_timeout_ms,
    :stream_subscription_cleanup_timeout_ms,
    :stream_mailbox_drain_interval_ms,
    :stream_cleanup_action
  ]

  @passthrough_fields [
    :id,
    :name,
    :stream_now_ms,
    :stream_mailbox_overflow_target,
    :stream_mailbox_backpressure_target,
    :stream_mailbox_final_flush_target,
    :stream_mailbox_rendered_event_target,
    :stream_lifecycle_target,
    :stream_operation_timeout_target,
    :stream_cleanup_target,
    :stream_process_handles,
    :stream_subscriptions,
    :stream_registered_buffers
  ]

  @key_aliases Map.new(@session_fields ++ @passthrough_fields, fn key ->
                 {Atom.to_string(key), key}
               end)

  @spec normalize_keys(map()) :: map()
  def normalize_keys(settings) do
    Map.new(settings, fn {key, value} -> {normalize_key(key), value} end)
  end

  @spec non_empty_string(map(), atom(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def non_empty_string(settings, key, default, path) do
    case Map.get(settings, key, default) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: invalid("#{path} must be a non-empty string"), else: {:ok, value}

      invalid_value ->
        invalid("#{path} must be a non-empty string, got: #{inspect(invalid_value)}")
    end
  end

  @spec optional_non_empty_string(map(), atom(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def optional_non_empty_string(settings, key, path) do
    case Map.fetch(settings, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: invalid("#{path} must be a non-empty string"), else: {:ok, value}

      {:ok, invalid_value} ->
        invalid("#{path} must be a non-empty string, got: #{inspect(invalid_value)}")
    end
  end

  @spec external_ids(map()) :: {:ok, map()} | {:error, term()}
  def external_ids(settings) do
    with {:ok, external_ids} <- map_field(settings, :external_ids, %{}, "external_ids") do
      external_ids
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
        cond do
          not external_id_key?(key) ->
            {:halt, invalid("external_ids keys must be non-empty strings or atoms")}

          not external_id_value?(value) ->
            {:halt,
             invalid(
               "external_ids.#{external_id_key_to_string(key)} must be a string, number, boolean, or nil"
             )}

          true ->
            {:cont, {:ok, Map.put(acc, external_id_key_to_string(key), value)}}
        end
      end)
    end
  end

  @spec map_field(map(), atom(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def map_field(settings, key, default, path) do
    case Map.get(settings, key, default) do
      value when is_map(value) -> {:ok, value}
      invalid_value -> invalid("#{path} must be a map, got: #{inspect(invalid_value)}")
    end
  end

  @spec positive_integer(map(), atom(), pos_integer(), String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  def positive_integer(settings, key, default, path) do
    case Map.get(settings, key, default) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      invalid_value ->
        invalid("#{path} must be a positive integer, got: #{inspect(invalid_value)}")
    end
  end

  @spec enum_field(map(), atom(), atom(), [atom()], String.t()) ::
          {:ok, atom()} | {:error, term()}
  def enum_field(settings, key, default, allowed, path) do
    case normalize_enum(Map.get(settings, key, default), allowed) do
      {:ok, value} -> {:ok, value}
      :error -> invalid("#{path} must be one of #{format_allowed(allowed)}")
    end
  end

  @spec optional_enum(map(), atom(), [atom()], String.t()) ::
          {:ok, atom() | nil} | {:error, term()}
  def optional_enum(settings, key, allowed, path) do
    case Map.fetch(settings, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} ->
        case normalize_enum(value, allowed) do
          {:ok, normalized} -> {:ok, normalized}
          :error -> invalid("#{path} must be one of #{format_allowed(allowed)}")
        end
    end
  end

  @spec transport(map()) :: {:ok, atom() | nil} | {:error, term()}
  def transport(settings),
    do: optional_enum(settings, :transport, @supported_transports, "transport")

  @spec overflow_path(map(), atom()) :: {:ok, atom()} | {:error, term()}
  def overflow_path(settings, default) do
    enum_field(
      settings,
      :stream_mailbox_overflow_path,
      default,
      @supported_overflow_paths,
      "stream_mailbox_overflow_path"
    )
  end

  @spec backpressure_behavior(map(), atom()) :: {:ok, atom()} | {:error, term()}
  def backpressure_behavior(settings, default) do
    enum_field(
      settings,
      :stream_mailbox_backpressure_behavior,
      default,
      @supported_backpressure_behaviors,
      "stream_mailbox_backpressure_behavior"
    )
  end

  @spec drain_interval(map()) :: {:ok, non_neg_integer() | :manual} | {:error, term()}
  def drain_interval(settings) do
    case Map.get(settings, :stream_mailbox_drain_interval_ms, 0) do
      :manual ->
        {:ok, :manual}

      "manual" ->
        {:ok, :manual}

      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      invalid_value ->
        invalid(
          "stream_mailbox_drain_interval_ms must be a non-negative integer or manual, got: #{inspect(invalid_value)}"
        )
    end
  end

  @spec cleanup_action(map()) :: {:ok, atom()} | {:error, term()}
  def cleanup_action(settings) do
    enum_field(
      settings,
      :stream_cleanup_action,
      :stop,
      @supported_cleanup_actions,
      "stream_cleanup_action"
    )
  end

  @spec validate_mailbox_bounds(pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def validate_mailbox_bounds(capacity, threshold) do
    if threshold <= capacity do
      :ok
    else
      invalid(
        "stream_mailbox_backpressure_threshold must be less than or equal to stream_mailbox_capacity"
      )
    end
  end

  @spec append_passthrough(keyword(), map()) :: keyword()
  def append_passthrough(keyword, settings) do
    Enum.reduce(@passthrough_fields, keyword, fn key, acc ->
      case Map.fetch(settings, key) do
        {:ok, value} -> Keyword.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    normalized_key =
      key
      |> String.trim()
      |> String.replace("-", "_")

    Map.get(@key_aliases, normalized_key, key)
  end

  defp normalize_key(key), do: key

  defp external_id_key?(key) when is_atom(key), do: key |> Atom.to_string() |> valid_id_key?()
  defp external_id_key?(key) when is_binary(key), do: valid_id_key?(key)
  defp external_id_key?(_key), do: false

  defp external_id_key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp external_id_key_to_string(key), do: key

  defp valid_id_key?(key), do: String.trim(key) == key and key != ""

  defp external_id_value?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp external_id_value?(_value), do: false

  defp normalize_enum(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  defp normalize_enum(value, allowed) when is_binary(value) do
    normalized = value |> String.trim() |> String.replace("-", "_")

    Enum.find_value(allowed, :error, fn allowed_value ->
      if Atom.to_string(allowed_value) == normalized, do: {:ok, allowed_value}
    end)
  end

  defp normalize_enum(_value, _allowed), do: :error

  defp format_allowed(values) do
    values
    |> Enum.map(&Atom.to_string/1)
    |> Enum.join(", ")
  end

  defp invalid(message), do: {:error, {:invalid_session_settings, message}}
end
