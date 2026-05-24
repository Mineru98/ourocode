defmodule Ourocode.IPC.ResponseFields do
  @moduledoc """
  Validates IPC response payload fields.
  """

  alias Ourocode.IPC.Error

  @ok_status "ok"
  @error_status "error"

  @type validation_error ::
          Error.validation_error()
          | {:missing_required_field, String.t()}
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

  @spec required_status(map()) :: {:ok, String.t()} | {:error, validation_error()}
  def required_status(map) do
    case Map.fetch(map, "status") do
      {:ok, value} -> normalize_status(value)
      :error -> {:error, {:missing_required_field, "status"}}
    end
  end

  @spec normalize_status(:ok | :error | String.t() | term()) ::
          {:ok, String.t()} | {:error, validation_error()}
  def normalize_status(:ok), do: {:ok, @ok_status}
  def normalize_status(:error), do: {:ok, @error_status}
  def normalize_status(@ok_status), do: {:ok, @ok_status}
  def normalize_status(@error_status), do: {:ok, @error_status}
  def normalize_status(other), do: {:error, {:invalid_field, "status", other}}

  @spec result_for_status(map(), String.t()) :: {:ok, map()} | {:error, validation_error()}
  def result_for_status(payload, @ok_status), do: required_map(payload, "result")
  def result_for_status(payload, @error_status), do: optional_map(payload, "result")

  @spec map_field(term(), String.t()) :: {:ok, map()} | {:error, validation_error()}
  def map_field(value, _field) when is_map(value), do: {:ok, value}
  def map_field(value, field), do: {:error, {:invalid_field, field, value}}

  @spec error_for_status(String.t(), map() | Error.t() | nil) ::
          {:ok, map() | nil} | {:error, validation_error()}
  def error_for_status(@ok_status, nil), do: {:ok, nil}
  def error_for_status(@ok_status, error), do: {:error, {:invalid_field, "error", error}}
  def error_for_status(@error_status, nil), do: {:error, {:missing_required_field, "error"}}
  def error_for_status(@error_status, error), do: optional_error(error)

  defp optional_map(map, field) do
    case Map.get(map, field, %{}) do
      value when is_map(value) -> {:ok, value}
      other -> {:error, {:invalid_field, field, other}}
    end
  end

  defp required_map(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, other} -> {:error, {:invalid_field, field, other}}
      :error -> {:error, {:missing_required_field, field}}
    end
  end

  defp optional_error(nil), do: {:ok, nil}

  defp optional_error(value) do
    with {:ok, error} <- Error.from_map(value) do
      {:ok, Error.to_map(error)}
    end
  end
end
