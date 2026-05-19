defmodule Ourocode.IPC.Error do
  @moduledoc """
  IPC/RPC error message schema for replaceable helper workers.

  Error messages are embedded in `Ourocode.IPC.Response` payloads when a Rust
  helper or external worker reports a failed request. The wire shape is strict
  so callers can safely journal, render, and route failures without inspecting
  helper-specific payloads.
  """

  @enforce_keys [:code, :message]
  defstruct [
    :code,
    :message,
    detail: nil
  ]

  @type detail :: map() | nil

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          detail: detail()
        }

  @type validation_error ::
          {:missing_required_field, String.t()}
          | {:invalid_field, String.t(), term()}

  @doc """
  Builds a validated IPC/RPC error.
  """
  @spec new(String.t(), String.t(), detail()) :: {:ok, t()} | {:error, validation_error()}
  def new(code, message, detail \\ nil) do
    with {:ok, code} <- non_blank_string(code, "code"),
         {:ok, message} <- non_blank_string(message, "message"),
         {:ok, detail} <- optional_detail(detail) do
      {:ok, %__MODULE__{code: code, message: message, detail: detail}}
    end
  end

  @doc """
  Validates and normalizes a decoded wire error map.
  """
  @spec from_map(map() | t()) :: {:ok, t()} | {:error, validation_error()}
  def from_map(%__MODULE__{} = error), do: new(error.code, error.message, error.detail)

  def from_map(error) when is_map(error) do
    with {:ok, code} <- required_non_blank_string(error, "code"),
         {:ok, message} <- required_non_blank_string(error, "message"),
         {:ok, detail} <- optional_detail(Map.get(error, "detail")) do
      new(code, message, detail)
    end
  end

  def from_map(other), do: {:error, {:invalid_field, "error", other}}

  @doc """
  Converts an IPC/RPC error to its wire map representation.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{detail: nil} = error) do
    %{
      "code" => error.code,
      "message" => error.message
    }
  end

  def to_map(%__MODULE__{} = error) do
    error
    |> to_map_without_detail()
    |> Map.put("detail", error.detail)
  end

  defp to_map_without_detail(%__MODULE__{} = error) do
    %{
      "code" => error.code,
      "message" => error.message
    }
  end

  defp required_non_blank_string(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> non_blank_string(value, field)
      :error -> {:error, {:missing_required_field, field}}
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

  defp optional_detail(nil), do: {:ok, nil}
  defp optional_detail(value) when is_map(value), do: {:ok, value}
  defp optional_detail(other), do: {:error, {:invalid_field, "detail", other}}
end
