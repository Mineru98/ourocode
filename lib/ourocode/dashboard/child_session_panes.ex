defmodule Ourocode.Dashboard.ChildSessionPanes do
  @moduledoc """
  Builds and updates child agent/session panes from MCP transport events.

  This module is intentionally pure. Transport processes emit journal-ready
  events; dashboard processes can apply those events to reconstruct pane state
  without owning the MCP lifecycle.
  """

  alias Ourocode.Dashboard.ChildSessionPaneEvent
  alias Ourocode.Dashboard.ChildSessionPaneAccess
  alias Ourocode.Dashboard.ChildSessionPaneEventRouter
  alias Ourocode.Dashboard.ChildSessionPaneProjection
  alias Ourocode.Dashboard.ChildSessionPaneRegistration
  alias Ourocode.Dashboard.ChildSessionPaneRenderer
  alias Ourocode.Dashboard.ChildSessionIdentity
  alias Ourocode.Dashboard.ChildSessionPaneFocus
  alias Ourocode.Dashboard.ChildSessionPaneOpen
  alias Ourocode.Dashboard.ChildSessionPaneState
  alias Ourocode.Journal.RelationshipRecoveryIndex

  @type pane_state :: %{
          required(:working) => list(map()),
          required(:completed) => list(map()),
          required(:focused) => String.t() | nil,
          required(:open) => list(String.t()),
          optional(:child_pane_registry) => child_pane_registry()
        }

  @type pane_key :: String.t()
  @type child_pane_registry :: %{optional(String.t()) => pane_key()}

  @type child_pane :: %{
          required(:id) => String.t(),
          required(:kind) => :child_session,
          required(:status) => :working,
          required(:child_id) => String.t(),
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:transport) => :stdio | :streamable_http | :sse,
          required(:external_ids) => map(),
          required(:stream_cursor) => map(),
          required(:pane_state) => map(),
          required(:created_at_ms) => integer(),
          required(:updated_at_ms) => integer()
        }

  @type rendered_child_pane :: %{
          required(:id) => String.t(),
          required(:kind) => :child_session,
          required(:title) => String.t(),
          required(:status) => String.t(),
          required(:line) => String.t(),
          required(:child_id) => String.t(),
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:transport) => String.t(),
          required(:external_ids) => map(),
          required(:stream_cursor) => map(),
          required(:pane_state) => map(),
          required(:rendered_sequences) => [map()],
          required(:replay_gap_error) => map() | nil,
          required(:stream_event_count) => non_neg_integer(),
          required(:updated_at_ms) => integer()
        }

  @type focused_child_pane_state :: %{
          required(:id) => String.t(),
          required(:child_id) => String.t(),
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:transport) => :stdio | :streamable_http | :sse,
          required(:external_ids) => map(),
          required(:stream_cursor) => map(),
          required(:pane_state) => map(),
          required(:status) => :working | :completed
        }

  @type child_session_resolution :: %{
          required(:kind) => :existing_session | :create_open_request,
          required(:identifier) => String.t(),
          required(:child_id) => String.t(),
          required(:pane_id) => String.t(),
          optional(:session) => child_pane(),
          optional(:request) => map()
        }

  @type open_child_session_error ::
          :invalid_child_session_resolution
          | :invalid_child_pane_metadata
          | :child_session_pane_not_found
          | :invalid_child_session_focus

  @type child_pane_metadata :: %{
          required(:child_id) => String.t(),
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:transport) => :stdio | :streamable_http | :sse,
          optional(:external_ids) => map(),
          optional(:stream_cursor) => map(),
          optional(:pane_state) => map(),
          optional(:created_at_ms) => integer(),
          optional(:updated_at_ms) => integer()
        }

  @type child_pane_updates :: %{
          optional(:status) => :working | :completed,
          optional(:runtime_source) => String.t(),
          optional(:transport) => :stdio | :streamable_http | :sse,
          optional(:external_ids) => map(),
          optional(:stream_cursor) => map(),
          optional(:pane_state) => map(),
          optional(:updated_at_ms) => integer()
        }

  @doc """
  Returns an empty child pane projection state.
  """
  @spec new() :: pane_state()
  def new do
    ChildSessionPaneState.new()
  end

  @doc """
  Replays persisted child pane lifecycle journal records into pane state.

  Persisted records may carry a dashboard-local `pane_id`. That ID is trusted
  as the stable UI identity for the child/session mapping, so a restart can
  rebuild focus/open state and later runtime stream events keep appending to
  the same pane instead of deriving a fresh ID from the runtime child ID.
  """
  @spec recover_from_journal([map()]) :: pane_state()
  @spec recover_from_journal([map()], pane_state()) :: pane_state()
  def recover_from_journal(events, initial_state \\ new())

  def recover_from_journal(events, initial_state)
      when is_list(events) and is_map(initial_state) do
    ChildSessionPaneEventRouter.recover_from_journal(events, initial_state)
  end

  @doc """
  Restores reconstructed parent-call to child-session mappings into live pane state.

  Restart recovery first rebuilds relationships from the journal, then uses this
  function to seed the live child pane registry. Existing live relationships win:
  if a pane already represents the same parent/child/session relationship, the
  registry is pointed at that pane and the recovered record updates it in place
  instead of adding a duplicate pane.
  """
  @spec restore_recovered_relationships(pane_state(), RelationshipRecoveryIndex.t()) ::
          {:ok, pane_state()} | {:error, :invalid_relationship_recovery_index}
  def restore_recovered_relationships(
        %{working: working, completed: completed, open: open} = state,
        %RelationshipRecoveryIndex{relationships: relationships} = index
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_list(relationships) do
    ChildSessionPaneEventRouter.restore_recovered_relationships(state, index)
  end

  def restore_recovered_relationships(_state, _index),
    do: {:error, :invalid_relationship_recovery_index}

  @doc """
  Applies an MCP event or persisted pane lifecycle journal record to pane state.

  Child-session events create or update a child pane for every MCP transport.
  Events without a runtime `childID` receive a stable fallback ID from trusted
  runtime IDs when they carry stream payloads, so the pane can still be
  recovered from the journal. Persisted pane lifecycle records may carry a
  stable `pane_id`, which is replayed before runtime lifecycle parsing.
  """
  @spec apply_event(pane_state(), map()) :: pane_state()
  def apply_event(
        %{working: working, completed: completed, focused: _focused, open: open} = state,
        event
      )
      when is_list(working) and is_list(completed) and is_list(open) do
    ChildSessionPaneEventRouter.apply_event(state, event)
  end

  @doc """
  Registers a child agent/session pane directly from runtime metadata.

  This is the multi-pane state-model entry point used when a caller already has
  trusted child/session metadata, without forcing it through transport event
  parsing. A child runtime ID is assigned one stable pane identifier in the
  registry; subsequent registrations for the same child update the existing
  pane instead of creating duplicates.
  """
  @spec register_child_pane(pane_state(), child_pane_metadata()) ::
          {:ok, pane_state()} | {:error, :invalid_child_pane_metadata}
  def register_child_pane(state, metadata),
    do: ChildSessionPaneRegistration.register(state, metadata)

  @doc """
  Retrieves a first-class child agent/session pane by stable pane ID.
  """
  @spec fetch_pane(pane_state(), String.t()) ::
          {:ok, child_pane()} | {:error, :child_session_pane_not_found}
  def fetch_pane(state, pane_id), do: ChildSessionPaneAccess.fetch(state, pane_id)

  @doc """
  Updates an existing first-class child pane by pane ID.

  The pane ID, runtime child ID, and parent call linkage are immutable. Update
  payload identity fields are ignored so UI-local edits cannot orphan focus/open
  state or silently move a child pane under a different parent.
  """
  @spec update_child_pane(pane_state(), String.t(), child_pane_updates() | map()) ::
          {:ok, pane_state()}
          | {:error, :child_session_pane_not_found | :invalid_child_pane_update}
  def update_child_pane(state, pane_id, updates),
    do: ChildSessionPaneAccess.update(state, pane_id, updates)

  @doc """
  Moves focus to an existing child agent/session pane.

  The selected ID may be either the runtime `child_id` or the local pane ID.
  Focus is resolved only from already-known panes and registry entries; this
  function never creates a pane, never renders one, and never assigns a new
  registry key.
  """
  @spec focus_session(pane_state(), String.t()) ::
          {:ok, pane_state()}
          | {:error, :child_session_pane_not_found | :invalid_child_session_focus}
  def focus_session(state, selected_id), do: ChildSessionPaneFocus.focus(state, selected_id)

  @doc """
  Resolves a user or runtime child/session identifier.

  Existing working and completed pane records win. If no record exists, the
  function returns a create-open request carrying the metadata needed to
  journal and register a new child pane later. This function is pure: it does
  not mutate pane state, create registry entries, or open/focus panes by itself.
  """
  @spec resolve_child_session(pane_state(), String.t(), map() | keyword()) ::
          {:ok, child_session_resolution()}
          | {:error, :invalid_child_session_identifier | :invalid_child_session_state}
  def resolve_child_session(state, identifier, options \\ %{})

  def resolve_child_session(
        %{working: working, completed: completed} = state,
        identifier,
        options
      )
      when is_list(working) and is_list(completed) and is_binary(identifier) do
    ChildSessionPaneOpen.resolve(state, identifier, options)
  end

  def resolve_child_session(%{working: working, completed: completed}, _identifier, _options)
      when is_list(working) and is_list(completed),
      do: {:error, :invalid_child_session_identifier}

  def resolve_child_session(_state, _identifier, _options),
    do: {:error, :invalid_child_session_state}

  @doc """
  Opens a child agent/session pane from a resolved child/session identifier.

  Existing resolutions focus the already-known pane. Create-open resolutions
  materialize a new child pane through the same metadata registration path used
  by transport and journal recovery code, then focus the resulting pane when no
  pane is currently active.
  """
  @spec open_resolved_child_session(pane_state(), child_session_resolution()) ::
          {:ok, pane_state()} | {:error, open_child_session_error()}
  def open_resolved_child_session(state, %{kind: :existing_session, pane_id: pane_id})
      when is_binary(pane_id) do
    ChildSessionPaneOpen.open_resolved(state, %{kind: :existing_session, pane_id: pane_id})
  end

  def open_resolved_child_session(
        %{working: working, completed: completed, focused: _focused, open: open} = state,
        %{kind: :create_open_request, request: request}
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(request) do
    ChildSessionPaneOpen.open_resolved(state, %{
      kind: :create_open_request,
      request: request
    })
  end

  def open_resolved_child_session(_state, _resolution),
    do: {:error, :invalid_child_session_resolution}

  @doc """
  Resolves and opens a child agent/session pane from a selected identifier.
  """
  @spec open_child_session(pane_state(), String.t(), map() | keyword()) ::
          {:ok, pane_state()}
          | {:error,
             open_child_session_error()
             | :invalid_child_session_identifier
             | :invalid_child_session_state}
  def open_child_session(state, identifier, options \\ %{}) do
    ChildSessionPaneOpen.open(state, identifier, options)
  end

  @doc """
  Returns the currently focused child agent/session pane state.

  This is a read-only state query for dashboard controllers, recovery logic, and
  future steering flows. It resolves only the existing top-level focus pointer,
  never creates panes, never updates the child registry, and never renders a
  terminal projection.
  """
  @spec focused_pane_state(pane_state()) ::
          {:ok, focused_child_pane_state()}
          | {:error, :no_focused_child_session_pane | :focused_child_session_pane_not_found}
  def focused_pane_state(state), do: ChildSessionPaneProjection.focused_state(state)

  @doc """
  Renders child session pane state into data a terminal UI can print.

  The collection renderer preserves the registered child-to-pane mapping: every
  registered child/session ID is projected as one stable rendered pane ID, and
  repeated registrations update that pane instead of creating another render
  item.
  """
  @spec render(pane_state() | child_pane()) :: map() | rendered_child_pane()
  def render(%{kind: :child_session} = pane), do: ChildSessionPaneRenderer.render(pane)

  def render(%{working: working, completed: completed, focused: focused, open: open} = state)
      when is_list(working) and is_list(completed) and is_list(open) do
    ChildSessionPaneProjection.render_collection(
      %{working: working, completed: completed, focused: focused, open: open},
      ChildSessionPaneState.registry(state)
    )
  end

  @spec render_line(child_pane() | rendered_child_pane()) :: String.t()
  def render_line(pane), do: ChildSessionPaneRenderer.render_line(pane)

  @doc """
  Registers the stable pane key for a child runtime ID.

  The registry is the dashboard-side mapping journal replay needs: a newly seen
  `childID` receives exactly one pane key, and later events for that same
  `childID` reuse the existing key instead of creating another pane.
  """
  @spec register_child_id(child_pane_registry(), String.t()) :: child_pane_registry()
  def register_child_id(registry, child_id) when is_map(registry) and is_binary(child_id) do
    ChildSessionIdentity.register_child_id(registry, child_id)
  end

  @doc """
  Returns the registry pane key for a child runtime ID, creating it if needed.
  """
  @spec child_pane_key(child_pane_registry(), String.t()) :: pane_key()
  def child_pane_key(registry, child_id) when is_map(registry) do
    ChildSessionIdentity.child_pane_key(registry, child_id)
  end

  @doc """
  Returns the stable generated pane ID for a child runtime/session ID.
  """
  @spec child_pane_id(String.t()) :: String.t()
  def child_pane_id(child_id) when is_binary(child_id),
    do: ChildSessionIdentity.child_pane_id(child_id)

  @doc """
  Builds a child pane from any MCP child-session lifecycle event.
  """
  @spec from_lifecycle_event(map()) :: {:ok, child_pane()} | :ignore
  def from_lifecycle_event(event), do: ChildSessionPaneEvent.from_lifecycle_event(event)

  @doc """
  Builds a child pane from a persisted child pane lifecycle journal record.
  """
  @spec from_pane_lifecycle_event(map()) :: {:ok, child_pane(), atom()} | :ignore
  def from_pane_lifecycle_event(event), do: ChildSessionPaneEvent.from_pane_lifecycle_event(event)

  @doc """
  Builds a child pane from a stdio MCP child-session event.

  Kept as a compatibility wrapper for callers that already route stdio events
  explicitly; the identity mapping itself is transport-neutral.
  """
  @spec from_stdio_event(map()) :: {:ok, child_pane()} | :ignore
  def from_stdio_event(event), do: ChildSessionPaneEvent.from_stdio_event(event)

  @doc """
  Removes stale live pane state when supervised stream cleanup completes.

  Cleanup events are emitted by the OTP stream boundary after process, port,
  subscription, buffer, and mailbox resources have been released. The dashboard
  treats them as authoritative for clearing only local live pane projections;
  runtime status remains owned by the external source.
  """
  @spec from_cleanup_event(map()) :: {:ok, map()} | :ignore
  def from_cleanup_event(event), do: Ourocode.Dashboard.ChildSessionCleanup.from_event(event)
end
