defmodule Ourocode.IPC.Request do
  @moduledoc """
  IPC/RPC request schema for replaceable helper workers.

  Requests are carried inside `Ourocode.IPC.Envelope` payloads. The outer
  envelope provides transport metadata and correlation; this schema keeps the
  helper command explicit and validates the method/action/params payload before
  anything is sent to an external Rust worker.
  """

  alias Ourocode.IPC.Envelope

  @message_type "ipc.rpc.request"

  @enforce_keys [:message_id, :method, :action]
  defstruct [
    :message_id,
    :method,
    :action,
    params: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          message_id: String.t(),
          method: String.t(),
          action: String.t(),
          params: map(),
          metadata: map()
        }

  @type validation_error ::
          Envelope.validation_error()
          | {:invalid_message_type, String.t()}
          | {:missing_required_field, String.t()}
          | {:invalid_field, String.t(), term()}

  @doc """
  Returns the envelope message type used for IPC/RPC requests.
  """
  @spec message_type() :: String.t()
  def message_type, do: @message_type

  @doc """
  Builds a validated request.
  """
  @spec new(String.t(), String.t(), String.t(), map(), map()) ::
          {:ok, t()} | {:error, validation_error()}
  def new(message_id, method, action, params \\ %{}, metadata \\ %{}) do
    with {:ok, message_id} <- non_blank_string(message_id, "message_id"),
         {:ok, method} <- non_blank_string(method, "method"),
         {:ok, action} <- non_blank_string(action, "action"),
         {:ok, params} <- map_field(params, "params"),
         {:ok, metadata} <- map_field(metadata, "metadata") do
      {:ok,
       %__MODULE__{
         message_id: message_id,
         method: method,
         action: action,
         params: params,
         metadata: metadata
       }}
    end
  end

  @doc """
  Builds and wraps a validated request in the shared IPC envelope.
  """
  @spec envelope(String.t(), String.t(), String.t(), map(), map()) ::
          {:ok, Envelope.t()} | {:error, validation_error()}
  def envelope(message_id, method, action, params \\ %{}, metadata \\ %{}) do
    with {:ok, request} <- new(message_id, method, action, params, metadata) do
      Envelope.new(request.message_id, @message_type, to_payload(request), request.metadata)
    end
  end

  @doc """
  Wraps a validated request struct in the shared IPC envelope.
  """
  @spec to_envelope(t()) :: {:ok, Envelope.t()} | {:error, validation_error()}
  def to_envelope(%__MODULE__{} = request) do
    with {:ok, request} <-
           new(
             request.message_id,
             request.method,
             request.action,
             request.params,
             request.metadata
           ) do
      Envelope.new(request.message_id, @message_type, to_payload(request), request.metadata)
    end
  end

  @doc """
  Serializes a validated request struct to the Rust helper IPC wire JSON.
  """
  @spec serialize(t(), module()) :: {:ok, String.t()} | {:error, validation_error() | term()}
  def serialize(%__MODULE__{} = request, codec \\ Ourocode.Json) do
    with {:ok, envelope} <- to_envelope(request) do
      {:ok, envelope |> Envelope.encode!(codec) |> IO.iodata_to_binary()}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @doc """
  Builds and serializes a request to the Rust helper IPC wire JSON.
  """
  @spec serialize(String.t(), String.t(), String.t(), map(), map(), module()) ::
          {:ok, String.t()} | {:error, validation_error() | term()}
  def serialize(
        message_id,
        method,
        action,
        params \\ %{},
        metadata \\ %{},
        codec \\ Ourocode.Json
      ) do
    with {:ok, request} <- new(message_id, method, action, params, metadata) do
      serialize(request, codec)
    end
  end

  @doc """
  Serializes a validated request struct to one newline-delimited IPC frame.
  """
  @spec serialize_line(t(), module()) :: {:ok, String.t()} | {:error, validation_error() | term()}
  def serialize_line(%__MODULE__{} = request, codec \\ Ourocode.Json) do
    with {:ok, encoded} <- serialize(request, codec) do
      {:ok, encoded <> "\n"}
    end
  end

  @doc """
  Builds and serializes one newline-delimited IPC frame for a Rust helper.
  """
  @spec serialize_line(String.t(), String.t(), String.t(), map(), map(), module()) ::
          {:ok, String.t()} | {:error, validation_error() | term()}
  def serialize_line(
        message_id,
        method,
        action,
        params \\ %{},
        metadata \\ %{},
        codec \\ Ourocode.Json
      ) do
    with {:ok, request} <- new(message_id, method, action, params, metadata) do
      serialize_line(request, codec)
    end
  end

  @doc """
  Validates a decoded request payload.
  """
  @spec from_payload(map(), String.t(), map()) :: {:ok, t()} | {:error, validation_error()}
  def from_payload(payload, message_id, metadata \\ %{})

  def from_payload(payload, message_id, metadata) when is_map(payload) do
    with {:ok, method} <- required_non_blank_string(payload, "method"),
         {:ok, action} <- required_non_blank_string(payload, "action"),
         {:ok, params} <- optional_map(payload, "params"),
         {:ok, request} <- new(message_id, method, action, params, metadata) do
      {:ok, request}
    end
  end

  def from_payload(other, _message_id, _metadata),
    do: {:error, {:invalid_field, "payload", other}}

  @doc """
  Validates and extracts a request from a shared IPC envelope.
  """
  @spec from_envelope(Envelope.t() | map()) :: {:ok, t()} | {:error, validation_error()}
  def from_envelope(%Envelope{message_type: @message_type} = envelope) do
    from_payload(envelope.payload, envelope.message_id, envelope.metadata)
  end

  def from_envelope(%Envelope{message_type: other}), do: {:error, {:invalid_message_type, other}}

  def from_envelope(envelope) when is_map(envelope) do
    with {:ok, envelope} <- Envelope.from_map(envelope) do
      from_envelope(envelope)
    end
  end

  def from_envelope(other), do: {:error, {:invalid_field, "envelope", other}}

  @doc """
  Converts a request to its envelope payload shape.
  """
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = request) do
    %{
      "method" => request.method,
      "action" => request.action,
      "params" => request.params
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

  defp optional_map(map, field) do
    case Map.get(map, field, %{}) do
      value when is_map(value) -> {:ok, value}
      other -> {:error, {:invalid_field, field, other}}
    end
  end

  defp map_field(value, _field) when is_map(value), do: {:ok, value}
  defp map_field(value, field), do: {:error, {:invalid_field, field, value}}
end
