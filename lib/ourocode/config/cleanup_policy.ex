defmodule Ourocode.Config.CleanupPolicy do
  @moduledoc """
  Validation for runtime cleanup and pane-retention policy maps.
  """

  @keys [
    :allowed_memory_growth_mb,
    :stale_cleanup_timeout_ms,
    :stream_subscription_cleanup_timeout_ms,
    :pane_state_retention_ms
  ]

  @doc """
  Returns the canonical cleanup policy keys.
  """
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc """
  Validates a cleanup policy for pane retention and cleanup monitoring.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, String.t()}
  def validate(policy) when is_map(policy) do
    normalized = normalize_keys(policy)

    with :ok <- reject_unknown_keys(normalized),
         :ok <- require_keys(normalized),
         :ok <- validate_values(normalized) do
      {:ok, Map.take(normalized, @keys)}
    end
  end

  def validate(policy) do
    {:error, "cleanup_policy must be configured as a map, got: #{inspect(policy)}"}
  end

  defp normalize_keys(policy) do
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

  defp reject_unknown_keys(policy) do
    unknown_keys = Map.keys(policy) -- @keys

    if unknown_keys == [] do
      :ok
    else
      {:error, "cleanup_policy contains unsupported keys: #{inspect(unknown_keys)}"}
    end
  end

  defp require_keys(policy) do
    missing_keys = @keys -- Map.keys(policy)

    if missing_keys == [] do
      :ok
    else
      {:error, "cleanup_policy is missing required keys: #{inspect(missing_keys)}"}
    end
  end

  defp validate_values(policy) do
    Enum.reduce_while(@keys, :ok, fn key, :ok ->
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
end
