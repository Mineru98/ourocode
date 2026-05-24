defmodule Ourocode.Dashboard.ParentMcpPane do
  @moduledoc """
  Live parent MCP call pane projection.

  Transports and normalizers emit journal-ready parent lifecycle events. This
  module keeps the dashboard projection pure and recoverable by applying those
  events to data-only pane state.
  """

  alias Ourocode.Dashboard.ParentMcpPaneEvent
  alias Ourocode.Dashboard.ParentMcpPaneLifecycle
  alias Ourocode.Dashboard.ParentMcpPaneRegistration
  alias Ourocode.Dashboard.ParentMcpPaneRenderer
  alias Ourocode.Dashboard.ParentMcpPaneUpdate

  @type pane_state :: %{
          required(:working) => list(map()),
          required(:completed) => list(map()),
          required(:focused) => String.t() | nil,
          required(:open) => list(String.t())
        }

  @type parent_pane :: %{
          required(:id) => String.t(),
          required(:kind) => :parent_mcp_call,
          required(:status) => :starting | :streaming | :completed | :failed,
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:transport) => atom(),
          required(:external_ids) => map(),
          required(:stream_cursor) => map(),
          required(:pane_state) => map(),
          required(:created_at_ms) => integer(),
          required(:updated_at_ms) => integer()
        }

  @type parent_pane_metadata :: %{
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:transport) => atom(),
          optional(:external_ids) => map(),
          optional(:stream_cursor) => map(),
          optional(:pane_state) => map(),
          optional(:request_id) => String.t(),
          optional(:method) => String.t(),
          optional(:params) => map(),
          optional(:created_at_ms) => integer(),
          optional(:updated_at_ms) => integer()
        }

  @type parent_pane_updates :: %{
          optional(:status) => :starting | :streaming | :completed | :failed,
          optional(:runtime_source) => String.t(),
          optional(:transport) => atom(),
          optional(:external_ids) => map(),
          optional(:stream_cursor) => map(),
          optional(:pane_state) => map(),
          optional(:request_id) => String.t(),
          optional(:method) => String.t(),
          optional(:params) => map(),
          optional(:result) => map(),
          optional(:error) => term(),
          optional(:notification) => map(),
          optional(:updated_at_ms) => integer()
        }

  @type rendered_parent_pane :: %{
          required(:id) => String.t(),
          required(:kind) => :parent_mcp_call,
          required(:title) => String.t(),
          required(:status) => String.t(),
          required(:lifecycle) => String.t(),
          required(:line) => String.t(),
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:transport) => String.t(),
          required(:external_ids) => map(),
          required(:stream_cursor) => map(),
          required(:event_count) => non_neg_integer(),
          required(:notification_count) => non_neg_integer(),
          required(:updated_at_ms) => integer()
        }

  @doc """
  Returns an empty parent MCP pane projection state.
  """
  @spec new() :: pane_state()
  def new do
    %{working: [], completed: [], focused: nil, open: []}
  end

  @doc """
  Applies a normalized MCP lifecycle event to the live parent pane state model.
  """
  @spec apply_event(pane_state(), map()) :: pane_state()
  def apply_event(
        %{working: working, completed: completed, focused: _focused, open: open} = state,
        event
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(event) do
    ParentMcpPaneLifecycle.apply_event(state, event)
  end

  @doc """
  Registers a parent MCP pane directly from runtime metadata.

  This is the state-model creation entry point for callers that already have a
  trusted parent call identity. The generated pane ID is stable for the parent
  call, and repeat registrations update the same first-class pane entry.
  """
  @spec register_parent_pane(pane_state(), parent_pane_metadata()) ::
          {:ok, pane_state()} | {:error, :invalid_parent_pane_metadata}
  def register_parent_pane(state, metadata),
    do: ParentMcpPaneRegistration.register(state, metadata)

  @doc """
  Retrieves a first-class parent MCP pane by generated pane ID.
  """
  @spec fetch_pane(pane_state(), String.t()) ::
          {:ok, parent_pane()} | {:error, :parent_pane_not_found}
  def fetch_pane(%{working: working, completed: completed}, pane_id)
      when is_list(working) and is_list(completed) and is_binary(pane_id) do
    case Enum.find(working ++ completed, &(&1.id == pane_id)) do
      %{kind: :parent_mcp_call} = pane -> {:ok, pane}
      _pane -> {:error, :parent_pane_not_found}
    end
  end

  def fetch_pane(_state, _pane_id), do: {:error, :parent_pane_not_found}

  @doc """
  Updates an existing first-class parent MCP pane by pane ID.

  The pane ID and parent call identity are immutable. Callers may pass
  `:id`, `"id"`, `:pane_id`, `"pane_id"`, or parent-call identity fields in
  the update payload, but those values are ignored so a dashboard update cannot
  orphan focus/open state or create a second pane for the same parent call.
  """
  @spec update_parent_pane(pane_state(), String.t(), parent_pane_updates() | map()) ::
          {:ok, pane_state()} | {:error, :parent_pane_not_found | :invalid_parent_pane_update}
  def update_parent_pane(
        %{working: working, completed: completed} = state,
        pane_id,
        updates
      )
      when is_list(working) and is_list(completed) and is_binary(pane_id) and is_map(updates) do
    case Enum.find(working ++ completed, &(&1.id == pane_id)) do
      %{kind: :parent_mcp_call} = pane ->
        updated_pane = ParentMcpPaneUpdate.apply(pane, updates)

        {:ok,
         %{
           state
           | working: replace_pane(working, pane_id, updated_pane),
             completed: replace_pane(completed, pane_id, updated_pane)
         }}

      _pane ->
        {:error, :parent_pane_not_found}
    end
  end

  def update_parent_pane(_state, _pane_id, _updates), do: {:error, :invalid_parent_pane_update}

  @doc """
  Returns the stable generated pane ID for a parent MCP call.
  """
  @spec parent_pane_id(String.t()) :: String.t()
  def parent_pane_id(parent_call_id) when is_binary(parent_call_id), do: pane_id(parent_call_id)

  @doc """
  Renders parent MCP pane state into data a terminal UI can print.

  The renderer is intentionally pure and consumes only the pane model produced
  by `apply_event/2`, so lifecycle state can be recovered from the journal and
  rendered without replaying transport processes.
  """
  @spec render(pane_state() | parent_pane()) :: map() | rendered_parent_pane()
  def render(%{kind: :parent_mcp_call} = pane), do: ParentMcpPaneRenderer.render(pane)

  def render(%{working: working, completed: completed, focused: focused, open: open})
      when is_list(working) and is_list(completed) and is_list(open) do
    %{
      id: :parent_mcp_calls,
      title: "Parent MCP",
      empty?: working == [] and completed == [],
      focused: focused,
      open: open,
      working: Enum.map(working, &ParentMcpPaneRenderer.render/1),
      completed: Enum.map(completed, &ParentMcpPaneRenderer.render/1)
    }
  end

  @doc """
  Formats a rendered or raw parent MCP pane as a compact terminal line.
  """
  @spec render_line(parent_pane() | rendered_parent_pane()) :: String.t()
  def render_line(pane), do: ParentMcpPaneRenderer.line(pane)

  @doc """
  Builds a parent MCP pane projection from a normalized lifecycle event.
  """
  @spec from_lifecycle_event(map()) :: {:ok, parent_pane()} | :ignore
  def from_lifecycle_event(event) when is_map(event) do
    ParentMcpPaneEvent.from_lifecycle_event(event)
  end

  def from_lifecycle_event(_event), do: :ignore

  @doc """
  Builds a local parent pane cleanup instruction from supervised stream cleanup.

  External runtime status remains trusted; cleanup only removes dashboard-local
  live projection state after the OTP stream boundary has released resources.
  """
  @spec from_cleanup_event(map()) :: {:ok, map()} | :ignore
  def from_cleanup_event(%{cleanup_reason: cleanup_reason, stream_kind: stream_kind} = event)
      when cleanup_reason in [:idle_timeout, :operation_timeout] and
             stream_kind in [:child, :session, :transport] do
    ParentMcpPaneEvent.from_cleanup_event(event)
  end

  def from_cleanup_event(%{lifecycle_type: :stream_terminated} = event) do
    ParentMcpPaneEvent.from_cleanup_event(event)
  end

  def from_cleanup_event(_event), do: :ignore

  defp replace_pane(panes, pane_id, updated_pane) do
    Enum.map(panes, fn
      %{id: ^pane_id} -> updated_pane
      pane -> pane
    end)
  end

  defp pane_id(parent_call_id), do: "parent-mcp:" <> parent_call_id
end
