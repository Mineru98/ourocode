defmodule Ourocode.MCP.LifecycleEvent do
  @moduledoc """
  Journal-ready MCP lifecycle event.

  The struct keeps parent call lifecycle events typed while remaining map-like
  for panes, tests, and journal writers that pattern match on event fields.
  """

  @enforce_keys [
    :event_seq,
    :type,
    :transport,
    :parent_call_id,
    :runtime_source,
    :external_ids,
    :occurred_at_ms
  ]
  defstruct [
    :event_seq,
    :type,
    :transport,
    :parent_call_id,
    :source,
    :runtime_source,
    :external_ids,
    :occurred_at_ms,
    :call_id,
    :hook_id,
    :request_id,
    :method,
    :params,
    :payload,
    :progress_state,
    :ordering_metadata,
    :completion_metadata,
    :result,
    :error,
    :error_details,
    :notification,
    :status,
    :headers,
    :raw_event,
    :cleanup_reason,
    :released_resources,
    :stale_cleanup_timeout_ms
  ]

  @type transport :: :stdio | :streamable_http | :sse

  @type t :: %__MODULE__{
          event_seq: non_neg_integer(),
          type: atom(),
          transport: transport() | atom(),
          parent_call_id: String.t(),
          source: atom() | String.t() | nil,
          runtime_source: String.t(),
          external_ids: map(),
          occurred_at_ms: integer(),
          call_id: String.t() | nil,
          hook_id: String.t() | nil,
          request_id: String.t() | nil,
          method: String.t() | nil,
          params: map() | list() | nil,
          payload: term(),
          progress_state: atom() | String.t() | nil,
          ordering_metadata: map() | nil,
          completion_metadata: map() | nil,
          result: term(),
          error: term(),
          error_details: term(),
          notification: map() | nil,
          status: non_neg_integer() | atom() | String.t() | nil,
          headers: [{String.t(), String.t()}] | nil,
          raw_event: map() | nil,
          cleanup_reason: atom() | nil,
          released_resources: map() | nil,
          stale_cleanup_timeout_ms: non_neg_integer() | nil
        }

  @behaviour Access

  @spec new(atom(), map()) :: t()
  def new(type, attrs) when is_atom(type) and is_map(attrs) do
    struct!(__MODULE__, Map.put(attrs, :type, type))
  end

  @impl Access
  def fetch(event, key) when is_atom(key) do
    event
    |> Map.from_struct()
    |> Map.fetch(key)
  end

  def fetch(event, key) do
    event
    |> Map.from_struct()
    |> Map.fetch(key)
  end

  @impl Access
  def get_and_update(event, key, fun) when is_function(fun, 1) do
    {current, event_map} =
      event
      |> Map.from_struct()
      |> Map.get_and_update(key, fun)

    {current, struct!(__MODULE__, event_map)}
  end

  @impl Access
  def pop(event, key) do
    {current, event_map} =
      event
      |> Map.from_struct()
      |> Map.pop(key)

    {current, struct!(__MODULE__, event_map)}
  end
end
