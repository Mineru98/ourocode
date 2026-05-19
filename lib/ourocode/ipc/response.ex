defmodule Ourocode.IPC.Response do
  @moduledoc """
  IPC/RPC response schema for replaceable helper workers.

  Responses are carried inside `Ourocode.IPC.Envelope` payloads. The envelope
  `message_id` identifies the response message itself, while payload
  `request_id` correlates the response back to the original request. Result and
  error payloads are maps so Elixir can validate worker replies before journal
  or UI state consumes them.
  """

  alias Ourocode.IPC.Envelope
  alias Ourocode.IPC.Error
  alias Ourocode.IPC.Request

  @message_type "ipc.rpc.response"
  @ok_status "ok"
  @error_status "error"

  @enforce_keys [:message_id, :request_id, :status]
  defstruct [
    :message_id,
    :request_id,
    :status,
    result: %{},
    error: nil,
    metadata: %{}
  ]

  @type status :: :ok | :error | String.t()

  @type t :: %__MODULE__{
          message_id: String.t(),
          request_id: String.t(),
          status: String.t(),
          result: map(),
          error: map() | nil,
          metadata: map()
        }

  @type validation_error ::
          Envelope.validation_error()
          | Error.validation_error()
          | {:invalid_message_type, String.t()}
          | {:missing_required_field, String.t()}
          | {:invalid_field, String.t(), term()}

  @doc """
  Returns the envelope message type used for IPC/RPC responses.
  """
  @spec message_type() :: String.t()
  def message_type, do: @message_type

  @doc """
  Builds a validated successful response.
  """
  @spec ok(String.t(), String.t(), map(), map()) :: {:ok, t()} | {:error, validation_error()}
  def ok(message_id, request_id, result \\ %{}, metadata \\ %{}) do
    new(message_id, request_id, @ok_status, result, nil, metadata)
  end

  @doc """
  Builds a validated error response.
  """
  @spec error(String.t(), String.t(), map() | Error.t(), map()) ::
          {:ok, t()} | {:error, validation_error()}
  def error(message_id, request_id, error, metadata \\ %{}) do
    new(message_id, request_id, @error_status, %{}, error, metadata)
  end

  @doc """
  Builds a successful response correlated to an existing request.
  """
  @spec ok_for_request(String.t(), Request.t(), map(), map()) ::
          {:ok, t()} | {:error, validation_error()}
  def ok_for_request(message_id, %Request{} = request, result \\ %{}, metadata \\ %{}) do
    ok(message_id, request.message_id, result, metadata)
  end

  @doc """
  Builds a validated response.
  """
  @spec new(String.t(), String.t(), status(), map(), map() | Error.t() | nil, map()) ::
          {:ok, t()} | {:error, validation_error()}
  def new(message_id, request_id, status, result \\ %{}, error \\ nil, metadata \\ %{}) do
    with {:ok, message_id} <- non_blank_string(message_id, "message_id"),
         {:ok, request_id} <- non_blank_string(request_id, "request_id"),
         {:ok, status} <- normalize_status(status),
         {:ok, result} <- map_field(result, "result"),
         {:ok, metadata} <- map_field(metadata, "metadata"),
         {:ok, error} <- error_for_status(status, error) do
      {:ok,
       %__MODULE__{
         message_id: message_id,
         request_id: request_id,
         status: status,
         result: result,
         error: error,
         metadata: metadata
       }}
    end
  end

  @doc """
  Builds and wraps a validated response in the shared IPC envelope.
  """
  @spec envelope(String.t(), String.t(), status(), map(), map() | Error.t() | nil, map()) ::
          {:ok, Envelope.t()} | {:error, validation_error()}
  def envelope(message_id, request_id, status, result \\ %{}, error \\ nil, metadata \\ %{}) do
    with {:ok, response} <- new(message_id, request_id, status, result, error, metadata) do
      Envelope.new(response.message_id, @message_type, to_payload(response), response.metadata)
    end
  end

  @doc """
  Validates a decoded response payload.
  """
  @spec from_payload(map(), String.t(), map()) :: {:ok, t()} | {:error, validation_error()}
  def from_payload(payload, message_id, metadata \\ %{})

  def from_payload(payload, message_id, metadata) when is_map(payload) do
    with {:ok, request_id} <- required_non_blank_string(payload, "request_id"),
         {:ok, status} <- required_status(payload),
         {:ok, result} <- result_for_status(payload, status),
         {:ok, response} <-
           new(message_id, request_id, status, result, Map.get(payload, "error"), metadata) do
      {:ok, response}
    end
  end

  def from_payload(other, _message_id, _metadata),
    do: {:error, {:invalid_field, "payload", other}}

  @doc """
  Validates and extracts a response from a shared IPC envelope.
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
  Deserializes a Rust helper IPC response JSON message.

  Rust helpers send the same shared IPC envelope that Elixir emits for
  requests. This entry point keeps the decoding and response validation in one
  place so callers do not accidentally consume unvalidated worker replies.
  """
  @spec deserialize(term(), module()) :: {:ok, t()} | {:error, validation_error() | term()}
  def deserialize(binary, codec \\ Ourocode.Json)

  def deserialize(binary, codec) when is_binary(binary) do
    with {:ok, envelope} <- Envelope.decode(binary, codec) do
      from_envelope(envelope)
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  def deserialize(other, _codec), do: {:error, {:invalid_field, "message", other}}

  @doc """
  Deserializes one newline-delimited Rust helper IPC response frame.
  """
  @spec deserialize_line(term(), module()) :: {:ok, t()} | {:error, validation_error() | term()}
  def deserialize_line(line, codec \\ Ourocode.Json)

  def deserialize_line(line, codec) when is_binary(line) do
    line
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
    |> deserialize(codec)
  end

  def deserialize_line(other, _codec), do: {:error, {:invalid_field, "line", other}}

  @doc """
  Converts a response to its envelope payload shape.
  """
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{status: @ok_status} = response) do
    %{
      "request_id" => response.request_id,
      "status" => response.status,
      "result" => response.result
    }
  end

  def to_payload(%__MODULE__{status: @error_status} = response) do
    %{
      "request_id" => response.request_id,
      "status" => response.status,
      "error" => response.error
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

  defp required_status(map) do
    case Map.fetch(map, "status") do
      {:ok, value} -> normalize_status(value)
      :error -> {:error, {:missing_required_field, "status"}}
    end
  end

  defp normalize_status(:ok), do: {:ok, @ok_status}
  defp normalize_status(:error), do: {:ok, @error_status}
  defp normalize_status(@ok_status), do: {:ok, @ok_status}
  defp normalize_status(@error_status), do: {:ok, @error_status}
  defp normalize_status(other), do: {:error, {:invalid_field, "status", other}}

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

  defp result_for_status(payload, @ok_status), do: required_map(payload, "result")
  defp result_for_status(payload, @error_status), do: optional_map(payload, "result")

  defp optional_error(nil), do: {:ok, nil}

  defp optional_error(value) do
    with {:ok, error} <- Error.from_map(value) do
      {:ok, Error.to_map(error)}
    end
  end

  defp map_field(value, _field) when is_map(value), do: {:ok, value}
  defp map_field(value, field), do: {:error, {:invalid_field, field, value}}

  defp error_for_status(@ok_status, nil), do: {:ok, nil}
  defp error_for_status(@ok_status, error), do: {:error, {:invalid_field, "error", error}}
  defp error_for_status(@error_status, nil), do: {:error, {:missing_required_field, "error"}}
  defp error_for_status(@error_status, error), do: optional_error(error)
end
