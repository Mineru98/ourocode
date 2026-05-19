defmodule Ourocode.MCP.ParentCallResult do
  @moduledoc """
  Result emitted by a parent MCP call transport.
  """

  @enforce_keys [:parent_call_id, :runtime_source, :transport, :external_ids, :response]
  defstruct [
    :parent_call_id,
    :runtime_source,
    :transport,
    :external_ids,
    :response,
    :status,
    :headers,
    :received_at
  ]

  @type t :: %__MODULE__{
          parent_call_id: String.t(),
          runtime_source: String.t(),
          transport: :streamable_http,
          external_ids: map(),
          response: map(),
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          received_at: integer()
        }
end
