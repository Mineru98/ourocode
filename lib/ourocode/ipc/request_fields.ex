defmodule Ourocode.IPC.RequestFields do
  @moduledoc """
  Validates IPC request payload fields.
  """

  @type validation_error ::
          {:missing_required_field, String.t()}
          | {:invalid_field, String.t(), term()}

  @spec required_non_blank_string(map(), String.t()) ::
          {:ok, String.t()} | {:error, validation_error()}
  def required_non_blank_string(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> non_blank_string(value, field)
      :error -> {:error, {:missing_required_field, field}}
    end
  end

  @spec non_blank_string(term(), String.t()) :: {:ok, String.t()} | {:error, validation_error()}
  def non_blank_string(value, field) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:error, {:invalid_field, field, value}}
    else
      {:ok, trimmed}
    end
  end

  def non_blank_string(value, field), do: {:error, {:invalid_field, field, value}}

  @spec optional_map(map(), String.t()) :: {:ok, map()} | {:error, validation_error()}
  def optional_map(map, field) do
    case Map.get(map, field, %{}) do
      value when is_map(value) -> {:ok, value}
      other -> {:error, {:invalid_field, field, other}}
    end
  end

  @spec map_field(term(), String.t()) :: {:ok, map()} | {:error, validation_error()}
  def map_field(value, _field) when is_map(value), do: {:ok, value}
  def map_field(value, field), do: {:error, {:invalid_field, field, value}}
end
