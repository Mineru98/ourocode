defmodule Ourocode.IPC.EnvelopeFields do
  @moduledoc """
  Validates shared IPC envelope fields.
  """

  @type validation_error ::
          {:missing_required_field, String.t()}
          | {:invalid_field, String.t(), term()}

  @spec required(map(), String.t()) :: {:ok, term()} | {:error, validation_error()}
  def required(envelope, field) do
    case Map.fetch(envelope, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_required_field, field}}
    end
  end

  @spec required_non_blank_string(map(), String.t()) ::
          {:ok, String.t()} | {:error, validation_error()}
  def required_non_blank_string(envelope, field) do
    with {:ok, value} <- required(envelope, field) do
      non_blank_string(value, field)
    end
  end

  @spec optional_map(map(), String.t()) :: {:ok, map()} | {:error, validation_error()}
  def optional_map(envelope, field) do
    case Map.get(envelope, field, %{}) do
      value when is_map(value) -> {:ok, value}
      other -> {:error, {:invalid_field, field, other}}
    end
  end

  defp non_blank_string(value, field) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:error, {:invalid_field, field, value}}
    else
      {:ok, trimmed}
    end
  end

  defp non_blank_string(value, field), do: {:error, {:invalid_field, field, value}}
end
