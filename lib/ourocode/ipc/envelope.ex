defmodule Ourocode.IPC.Envelope do
  @moduledoc """
  Shared IPC/RPC envelope for replaceable helper processes.

  The wire shape is intentionally small and string-keyed so Elixir and Rust
  helpers can exchange messages without sharing implementation details.
  """

  @current_version 1

  @enforce_keys [:version, :message_id, :message_type]
  defstruct [
    :version,
    :message_id,
    :message_type,
    payload: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          version: pos_integer(),
          message_id: String.t(),
          message_type: String.t(),
          payload: map(),
          metadata: map()
        }

  @type validation_error ::
          :unsupported_version
          | {:missing_required_field, String.t()}
          | {:invalid_field, String.t(), term()}

  @doc """
  Returns the current IPC envelope schema version.
  """
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  Builds an envelope using the current schema version.
  """
  @spec new(String.t(), String.t(), map(), map()) :: {:ok, t()} | {:error, validation_error()}
  def new(message_id, message_type, payload \\ %{}, metadata \\ %{}) do
    from_map(%{
      "version" => @current_version,
      "message_id" => message_id,
      "message_type" => message_type,
      "payload" => payload,
      "metadata" => metadata
    })
  end

  @doc """
  Validates and normalizes a decoded wire envelope.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, validation_error()}
  def from_map(envelope) when is_map(envelope) do
    with {:ok, version} <- required(envelope, "version"),
         :ok <- validate_version(version),
         {:ok, message_id} <- required_non_blank_string(envelope, "message_id"),
         {:ok, message_type} <- required_non_blank_string(envelope, "message_type"),
         {:ok, payload} <- optional_map(envelope, "payload"),
         {:ok, metadata} <- optional_map(envelope, "metadata") do
      {:ok,
       %__MODULE__{
         version: version,
         message_id: message_id,
         message_type: message_type,
         payload: payload,
         metadata: metadata
       }}
    end
  end

  def from_map(other), do: {:error, {:invalid_field, "envelope", other}}

  @doc """
  Converts an envelope struct to its wire map representation.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = envelope) do
    %{
      "version" => envelope.version,
      "message_id" => envelope.message_id,
      "message_type" => envelope.message_type,
      "payload" => envelope.payload,
      "metadata" => envelope.metadata
    }
  end

  @doc """
  Encodes an envelope to JSON using the project codec.
  """
  @spec encode!(t(), module()) :: iodata()
  def encode!(%__MODULE__{} = envelope, codec \\ Ourocode.Json) do
    envelope
    |> to_map()
    |> codec.encode!()
  end

  @doc """
  Decodes and validates an envelope from JSON using the project codec.
  """
  @spec decode(String.t(), module()) :: {:ok, t()} | {:error, term()}
  def decode(binary, codec \\ Ourocode.Json) when is_binary(binary) do
    with {:ok, decoded} <- codec.decode(binary) do
      from_map(decoded)
    end
  end

  defp required(envelope, field) do
    case Map.fetch(envelope, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_required_field, field}}
    end
  end

  defp required_non_blank_string(envelope, field) do
    with {:ok, value} <- required(envelope, field) do
      case value do
        value when is_binary(value) ->
          trimmed = String.trim(value)

          if trimmed == "" do
            {:error, {:invalid_field, field, value}}
          else
            {:ok, trimmed}
          end

        other ->
          {:error, {:invalid_field, field, other}}
      end
    end
  end

  defp validate_version(@current_version), do: :ok
  defp validate_version(_other), do: {:error, :unsupported_version}

  defp optional_map(envelope, field) do
    case Map.get(envelope, field, %{}) do
      value when is_map(value) -> {:ok, value}
      other -> {:error, {:invalid_field, field, other}}
    end
  end
end
