defmodule Ourocode.Dashboard.ChildSessionPanes do
  @moduledoc """
  Builds and updates child agent/session panes from MCP transport events.

  This module is intentionally pure. Transport processes emit journal-ready
  events; dashboard processes can apply those events to reconstruct pane state
  without owning the MCP lifecycle.
  """

  alias Ourocode.MCP.ChildSessionCreationParser
  alias Ourocode.MCP.RuntimeEventParser
  alias Ourocode.MCP.Transport.StdoutJsonlParser
  alias Ourocode.Journal
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

  @fallback_metadata_precedence [:primary, :stdout_jsonl, :runtime_event]

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

  @pane_lifecycle_types MapSet.new([
                          :child_pane_registered,
                          :child_pane_opened,
                          :child_pane_focused,
                          :child_pane_updated,
                          :child_pane_completed
                        ])

  @doc """
  Returns an empty child pane projection state.
  """
  @spec new() :: pane_state()
  def new do
    %{working: [], completed: [], focused: nil, open: [], child_pane_registry: %{}}
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
    Enum.reduce(events, initial_state, &apply_event(&2, &1))
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
        %RelationshipRecoveryIndex{relationships: relationships}
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_list(relationships) do
    relationships
    |> Enum.sort_by(& &1.first_event_seq)
    |> Enum.reduce_while({:ok, state}, fn relationship, {:ok, state} ->
      case restore_relationship(state, relationship) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
        %{working: working, completed: completed, focused: focused, open: open} = state,
        event
      )
      when is_list(working) and is_list(completed) and is_list(open) do
    case from_cleanup_event(event) do
      {:ok, cleanup} ->
        apply_cleanup_event(state, cleanup)

      :ignore ->
        case from_pane_lifecycle_event(event) do
          {:ok, pane, lifecycle_type} ->
            apply_pane_lifecycle(state, pane, lifecycle_type)

          :ignore ->
            apply_runtime_lifecycle_event(state, event, focused)
        end
    end
  end

  defp apply_runtime_lifecycle_event(
         %{working: working, completed: completed, open: open} = state,
         event,
         focused
       ) do
    case from_lifecycle_event(event) do
      {:ok, pane} ->
        existing_panes = working ++ completed
        pane = stabilize_fallback_child_id(existing_panes, pane)
        reusable_pane = reusable_session_pane_for_event(existing_panes, pane)

        registry =
          state
          |> child_pane_registry()
          |> register_child_id(pane.child_id, reusable_pane)

        pane = %{pane | id: Map.fetch!(registry, pane.child_id)}
        pane_id = pane.id
        existing_pane = Enum.find(existing_panes, &(&1.id == pane_id))

        if replayed_at_or_before_acknowledged_cursor?(pane, existing_pane) do
          Map.put(state, :child_pane_registry, registry)
        else
          pane = surface_replay_cursor_gap(pane, existing_pane, pane_id)

          working =
            working
            |> upsert_pane(merge_existing(existing_panes, pane), fn existing ->
              merge_pane(existing, pane)
            end)

          %{
            state
            | working: working,
              completed: reject_pane(completed, pane_id),
              focused: focused || pane_id,
              open: append_once(open, pane_id)
          }
          |> Map.put(:child_pane_registry, registry)
        end

      :ignore ->
        state
    end
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
  def register_child_pane(
        %{working: working, completed: completed, focused: focused, open: open} = state,
        metadata
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(metadata) do
    with {:ok, child_id} <- metadata_string(metadata, :child_id),
         {:ok, parent_call_id} <- metadata_string(metadata, :parent_call_id),
         {:ok, runtime_source} <- metadata_string(metadata, :runtime_source),
         {:ok, transport} <- metadata_transport(metadata) do
      now = metadata_integer(metadata, :updated_at_ms) || System.system_time(:millisecond)
      created_at_ms = metadata_integer(metadata, :created_at_ms) || now

      external_ids =
        metadata
        |> metadata_map(:external_ids, %{})
        |> Map.put_new("childID", child_id)

      existing_panes = working ++ completed
      reusable_pane = reusable_session_pane(existing_panes, external_ids)

      registry =
        state
        |> child_pane_registry()
        |> register_child_id(child_id, reusable_pane)

      pane_id = Map.fetch!(registry, registry_child_id(child_id))
      existing_pane = Enum.find(working ++ completed, &(&1.id == pane_id))

      pane = %{
        id: pane_id,
        kind: :child_session,
        status: :working,
        child_id: registry_child_id(child_id),
        parent_call_id: parent_call_id,
        runtime_source: runtime_source,
        transport: transport,
        external_ids: external_ids,
        stream_cursor:
          metadata
          |> metadata_map(:stream_cursor, %{})
          |> Map.merge(%{
            transport: transport,
            child_id: registry_child_id(child_id)
          }),
        pane_state: metadata_pane_state(metadata, existing_pane),
        created_at_ms: created_at_ms,
        updated_at_ms: now
      }

      pane_for_insert = merge_existing(working ++ completed, pane)

      {:ok,
       state
       |> Map.put(
         :working,
         upsert_pane(working, pane_for_insert, fn existing -> merge_pane(existing, pane) end)
       )
       |> Map.put(:completed, reject_pane(completed, pane_id))
       |> Map.put(:focused, focused || pane_id)
       |> Map.put(:open, append_once(open, pane_id))
       |> Map.put(:child_pane_registry, registry)}
    else
      _error -> {:error, :invalid_child_pane_metadata}
    end
  end

  def register_child_pane(_state, _metadata), do: {:error, :invalid_child_pane_metadata}

  @doc """
  Retrieves a first-class child agent/session pane by stable pane ID.
  """
  @spec fetch_pane(pane_state(), String.t()) ::
          {:ok, child_pane()} | {:error, :child_session_pane_not_found}
  def fetch_pane(%{working: working, completed: completed}, pane_id)
      when is_list(working) and is_list(completed) and is_binary(pane_id) do
    case Enum.find(working ++ completed, &(&1.id == pane_id)) do
      %{kind: :child_session} = pane -> {:ok, pane}
      _pane -> {:error, :child_session_pane_not_found}
    end
  end

  def fetch_pane(_state, _pane_id), do: {:error, :child_session_pane_not_found}

  @doc """
  Updates an existing first-class child pane by pane ID.

  The pane ID, runtime child ID, and parent call linkage are immutable. Update
  payload identity fields are ignored so UI-local edits cannot orphan focus/open
  state or silently move a child pane under a different parent.
  """
  @spec update_child_pane(pane_state(), String.t(), child_pane_updates() | map()) ::
          {:ok, pane_state()}
          | {:error, :child_session_pane_not_found | :invalid_child_pane_update}
  def update_child_pane(
        %{working: working, completed: completed} = state,
        pane_id,
        updates
      )
      when is_list(working) and is_list(completed) and is_binary(pane_id) and is_map(updates) do
    case Enum.find(working ++ completed, &(&1.id == pane_id)) do
      %{kind: :child_session} = pane ->
        updated_pane = apply_child_pane_updates(pane, updates)

        {:ok,
         %{
           state
           | working: replace_pane(working, pane_id, updated_pane),
             completed: replace_pane(completed, pane_id, updated_pane)
         }}

      _pane ->
        {:error, :child_session_pane_not_found}
    end
  end

  def update_child_pane(_state, _pane_id, _updates), do: {:error, :invalid_child_pane_update}

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
  def focus_session(%{working: working, completed: completed, open: open} = state, selected_id)
      when is_list(working) and is_list(completed) and is_list(open) and is_binary(selected_id) do
    selected_id = registry_child_id(selected_id)

    with true <- selected_id != "",
         {:ok, pane_id} <- existing_pane_id(state, selected_id) do
      {:ok,
       state
       |> Map.put(:working, mark_focused_panes(working, pane_id))
       |> Map.put(:completed, mark_focused_panes(completed, pane_id))
       |> Map.put(:focused, pane_id)
       |> Map.put(:open, append_once(open, pane_id))}
    else
      false -> {:error, :invalid_child_session_focus}
      :error -> {:error, :child_session_pane_not_found}
    end
  end

  def focus_session(_state, _selected_id), do: {:error, :invalid_child_session_focus}

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
    with {:ok, normalized_identifier} <- normalize_selected_identifier(identifier),
         {:ok, create_child_id} <- create_request_child_id(normalized_identifier) do
      case find_existing_pane(state, normalized_identifier) do
        %{id: pane_id, child_id: child_id} = pane ->
          {:ok,
           %{
             kind: :existing_session,
             identifier: normalized_identifier,
             child_id: child_id,
             pane_id: pane_id,
             session: pane
           }}

        nil ->
          case find_existing_pane_from_options(state, options) do
            %{id: pane_id, child_id: child_id} = pane ->
              {:ok,
               %{
                 kind: :existing_session,
                 identifier: normalized_identifier,
                 child_id: child_id,
                 pane_id: pane_id,
                 session: pane
               }}

            nil ->
              pane_id = create_request_pane_id(state, create_child_id)

              {:ok,
               %{
                 kind: :create_open_request,
                 identifier: normalized_identifier,
                 child_id: create_child_id,
                 pane_id: pane_id,
                 request:
                   create_open_request(create_child_id, normalized_identifier, pane_id, options)
               }}
          end
      end
    end
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
    focus_session(state, pane_id)
  end

  def open_resolved_child_session(
        %{working: working, completed: completed, focused: focused, open: open} = state,
        %{kind: :create_open_request, request: request}
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(request) do
    should_focus? = no_active_child_pane?(focused, open)

    with {:ok, state} <-
           register_child_pane(state, create_open_request_metadata(request, should_focus?)) do
      pane_id = metadata_value(request, :pane_id)

      if should_focus? and is_binary(pane_id) do
        focus_session(state, pane_id)
      else
        {:ok, state}
      end
    end
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
    with {:ok, resolution} <- resolve_child_session(state, identifier, options) do
      open_resolved_child_session(state, resolution)
    end
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
  def focused_pane_state(%{working: working, completed: completed, focused: focused})
      when is_list(working) and is_list(completed) and is_binary(focused) and focused != "" do
    case Enum.find(working ++ completed, &(&1.id == focused)) do
      %{id: pane_id, kind: :child_session} = pane ->
        {:ok, pane |> Map.put(:pane_state, focused_pane_map(pane, pane_id))}

      _pane ->
        {:error, :focused_child_session_pane_not_found}
    end
  end

  def focused_pane_state(%{focused: nil}), do: {:error, :no_focused_child_session_pane}
  def focused_pane_state(%{focused: ""}), do: {:error, :no_focused_child_session_pane}
  def focused_pane_state(_state), do: {:error, :focused_child_session_pane_not_found}

  @doc """
  Renders child session pane state into data a terminal UI can print.

  The collection renderer preserves the registered child-to-pane mapping: every
  registered child/session ID is projected as one stable rendered pane ID, and
  repeated registrations update that pane instead of creating another render
  item.
  """
  @spec render(pane_state() | child_pane()) :: map() | rendered_child_pane()
  def render(%{kind: :child_session} = pane), do: render_pane(pane)

  def render(%{working: working, completed: completed, focused: focused, open: open} = state)
      when is_list(working) and is_list(completed) and is_list(open) do
    working = distinct_panes(working)
    completed = completed |> reject_registered(working) |> distinct_panes()

    %{
      id: :child_session_panes,
      title: "Child Sessions",
      empty?: working == [] and completed == [],
      focused: focused,
      open: open,
      child_pane_registry: child_pane_registry(state),
      working: Enum.map(working, &render_pane/1),
      completed: Enum.map(completed, &render_pane/1)
    }
  end

  @doc """
  Formats a rendered or raw child session pane as a compact terminal line.
  """
  @spec render_line(child_pane() | rendered_child_pane()) :: String.t()
  def render_line(%{line: line}) when is_binary(line), do: line
  def render_line(%{kind: :child_session} = pane), do: pane |> render_pane() |> Map.fetch!(:line)

  @doc """
  Registers the stable pane key for a child runtime ID.

  The registry is the dashboard-side mapping journal replay needs: a newly seen
  `childID` receives exactly one pane key, and later events for that same
  `childID` reuse the existing key instead of creating another pane.
  """
  @spec register_child_id(child_pane_registry(), String.t()) :: child_pane_registry()
  def register_child_id(registry, child_id) when is_map(registry) and is_binary(child_id) do
    child_id = registry_child_id(child_id)

    Map.put_new(registry, child_id, pane_id(child_id))
  end

  defp register_child_id(registry, child_id, %{id: pane_id})
       when is_map(registry) and is_binary(child_id) and is_binary(pane_id) do
    child_id = registry_child_id(child_id)

    Map.put_new(registry, child_id, pane_id)
  end

  defp register_child_id(registry, child_id, _reusable_pane),
    do: register_child_id(registry, child_id)

  @doc """
  Returns the registry pane key for a child runtime ID, creating it if needed.
  """
  @spec child_pane_key(child_pane_registry(), String.t()) :: pane_key()
  def child_pane_key(registry, child_id) when is_map(registry) do
    child_id = registry_child_id(child_id)

    registry
    |> register_child_id(child_id)
    |> Map.fetch!(child_id)
  end

  @doc """
  Returns the stable generated pane ID for a child runtime/session ID.
  """
  @spec child_pane_id(String.t()) :: String.t()
  def child_pane_id(child_id) when is_binary(child_id), do: pane_id(registry_child_id(child_id))

  @doc """
  Builds a child pane from any MCP child-session lifecycle event.
  """
  @spec from_lifecycle_event(map()) :: {:ok, child_pane()} | :ignore
  def from_lifecycle_event(event) when is_map(event) do
    with {:ok, {child_id, child_id_source}} <- child_runtime_id(event),
         {:ok, parent_call_id} <- required_string(event, :parent_call_id),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, transport} <- required_transport(event),
         true <- child_pane_event?(event) do
      event_seq = Map.get(event, :event_seq, 0)
      occurred_at_ms = Map.get(event, :occurred_at_ms, System.system_time(:millisecond))

      {:ok,
       %{
         id: pane_id(child_id),
         kind: :child_session,
         status: :working,
         child_id: child_id,
         parent_call_id: parent_call_id,
         runtime_source: runtime_source,
         transport: transport,
         external_ids: external_ids(event, child_id, child_id_source),
         stream_cursor: stream_cursor(event, transport, event_seq, child_id),
         pane_state: %{
           open?: true,
           focused?: false,
           renderer: :default_child_session,
           last_event_seq: event_seq,
           stream_entries: stream_entries_for_event(event, event_seq, occurred_at_ms)
         },
         created_at_ms: occurred_at_ms,
         updated_at_ms: occurred_at_ms
       }}
    else
      _ -> :ignore
    end
  end

  def from_lifecycle_event(_event), do: :ignore

  @doc """
  Builds a child pane from a persisted child pane lifecycle journal record.
  """
  @spec from_pane_lifecycle_event(map()) :: {:ok, child_pane(), atom()} | :ignore
  def from_pane_lifecycle_event(event) when is_map(event) do
    with {:ok, lifecycle_type} <- pane_lifecycle_type(event),
         {:ok, child_id} <- metadata_string(event, :child_id),
         {:ok, pane_id} <- metadata_string_any(event, [:pane_id, :id]),
         {:ok, parent_call_id} <- metadata_string(event, :parent_call_id),
         {:ok, runtime_source} <- metadata_string(event, :runtime_source),
         {:ok, transport} <- metadata_transport(event) do
      now =
        metadata_integer(event, :updated_at_ms) ||
          metadata_integer(event, :occurred_at_ms) ||
          System.system_time(:millisecond)

      created_at_ms = metadata_integer(event, :created_at_ms) || now

      external_ids =
        event
        |> metadata_map(:external_ids, %{})
        |> Map.put_new("childID", child_id)

      {:ok,
       %{
         id: pane_id,
         kind: :child_session,
         status: metadata_status(event, lifecycle_type),
         child_id: child_id,
         parent_call_id: parent_call_id,
         runtime_source: runtime_source,
         transport: transport,
         external_ids: external_ids,
         stream_cursor:
           event
           |> metadata_map(:stream_cursor, %{})
           |> Map.merge(%{
             transport: transport,
             child_id: child_id
           }),
         pane_state:
           %{
             open?: true,
             focused?: false,
             renderer: :default_child_session,
             last_acknowledged_stream_cursor: metadata_acknowledged_stream_cursor(event)
           }
           |> Map.merge(metadata_pane_projection_state(event)),
         created_at_ms: created_at_ms,
         updated_at_ms: now
       }, lifecycle_type}
    else
      _error -> :ignore
    end
  end

  def from_pane_lifecycle_event(_event), do: :ignore

  @doc """
  Builds a child pane from a stdio MCP child-session event.

  Kept as a compatibility wrapper for callers that already route stdio events
  explicitly; the identity mapping itself is transport-neutral.
  """
  @spec from_stdio_event(map()) :: {:ok, child_pane()} | :ignore
  def from_stdio_event(%{transport: :stdio} = event), do: from_lifecycle_event(event)
  def from_stdio_event(_event), do: :ignore

  @doc """
  Removes stale live pane state when supervised stream cleanup completes.

  Cleanup events are emitted by the OTP stream boundary after process, port,
  subscription, buffer, and mailbox resources have been released. The dashboard
  treats them as authoritative for clearing only local live pane projections;
  runtime status remains owned by the external source.
  """
  @spec from_cleanup_event(map()) :: {:ok, map()} | :ignore
  def from_cleanup_event(%{cleanup_reason: cleanup_reason, stream_kind: :child} = event)
      when cleanup_reason in [:idle_timeout, :operation_timeout] do
    with {:ok, child_id} <- cleanup_child_id(event) do
      {:ok, %{kind: :child, child_id: child_id}}
    end
  end

  def from_cleanup_event(%{cleanup_reason: cleanup_reason, stream_kind: :session} = event)
      when cleanup_reason in [:idle_timeout, :operation_timeout] do
    with {:ok, session_id} <- cleanup_session_id(event) do
      {:ok, %{kind: :session, session_id: session_id}}
    end
  end

  def from_cleanup_event(%{lifecycle_type: :stream_terminated} = event) do
    from_cleanup_event(Map.delete(event, :lifecycle_type))
  end

  def from_cleanup_event(_event), do: :ignore

  defp render_pane(%{kind: :child_session} = pane) do
    stream_entries = stream_entries(pane)
    rendered_sequences = rendered_sequences(pane, stream_entries)
    rendered_pane_state = put_rendered_sequence_ids(pane.pane_state, rendered_sequences)

    rendered = %{
      id: pane.id,
      kind: :child_session,
      title: child_title(pane),
      status: Atom.to_string(pane.status),
      child_id: pane.child_id,
      parent_call_id: pane.parent_call_id,
      runtime_source: pane.runtime_source,
      transport: Atom.to_string(pane.transport),
      external_ids: pane.external_ids,
      stream_cursor: pane.stream_cursor,
      pane_state: rendered_pane_state,
      rendered_sequences: rendered_sequences,
      replay_gap_error: replay_gap_error(pane),
      stream_event_count: length(stream_entries),
      last_event_seq: get_in(rendered_pane_state, [:last_event_seq]),
      updated_at_ms: pane.updated_at_ms
    }

    Map.put(rendered, :line, line_for(rendered))
  end

  defp rendered_sequences(%{id: pane_id, child_id: child_id}, stream_entries) do
    stream_entries
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, rendered_index} ->
      event_seq = stream_entry_value(entry, :event_seq)
      runtime_seq = stream_entry_value(entry, :runtime_seq)

      %{
        id: rendered_sequence_id(pane_id, entry, event_seq, runtime_seq, rendered_index),
        pane_id: pane_id,
        child_id: child_id,
        child_event_id: stream_entry_value(entry, :child_event_id),
        event_seq: event_seq,
        runtime_seq: runtime_seq,
        rendered_index: rendered_index
      }
    end)
  end

  defp put_rendered_sequence_ids(pane_state, []), do: pane_state

  defp put_rendered_sequence_ids(pane_state, rendered_sequences) when is_map(pane_state) do
    entries = Map.get(pane_state, :stream_entries, [])

    rendered_entries =
      entries
      |> Enum.zip(rendered_sequences)
      |> Enum.map(fn {entry, sequence} ->
        if is_map(entry) do
          Map.put(entry, :rendered_sequence_id, sequence.id)
          |> Map.put(:child_event_id, sequence.child_event_id)
        else
          entry
        end
      end)

    Map.put(pane_state, :stream_entries, rendered_entries)
  end

  defp put_rendered_sequence_ids(pane_state, _rendered_sequences), do: pane_state

  defp rendered_sequence_id(pane_id, entry, event_seq, runtime_seq, rendered_index) do
    case stream_entry_value(entry, :child_event_id) do
      child_event_id when is_binary(child_event_id) and child_event_id != "" ->
        "rendered-seq:" <> child_event_id

      _child_event_id ->
        [
          "rendered-seq",
          pane_id,
          "event=#{sequence_component(event_seq)}",
          "runtime=#{sequence_component(runtime_seq)}",
          "index=#{rendered_index}"
        ]
        |> Enum.join(":")
    end
  end

  defp sequence_component(nil), do: "none"
  defp sequence_component(value), do: to_string(value)

  defp stream_entry_value(entry, key) when is_map(entry) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp stream_entry_value(_entry, _key), do: nil

  defp line_for(rendered) do
    [
      "[#{rendered.status}]",
      "child=#{rendered.child_id}",
      "pane=#{rendered.id}",
      "parent=#{rendered.parent_call_id}",
      "runtime=#{rendered.runtime_source}",
      "transport=#{rendered.transport}",
      maybe_segment("seq", rendered.last_event_seq),
      replay_gap_segment(rendered.replay_gap_error),
      "events=#{rendered.stream_event_count}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp child_title(pane) do
    case get_in(pane, [:pane_state, :title]) do
      title when is_binary(title) and title != "" -> title
      _title -> "Child Session"
    end
  end

  defp stream_entries(%{pane_state: pane_state}) when is_map(pane_state) do
    case Map.get(pane_state, :stream_entries, []) do
      entries when is_list(entries) -> entries
      _entries -> []
    end
  end

  defp stream_entries(_pane), do: []

  defp distinct_panes(panes) do
    panes
    |> Enum.reduce({[], MapSet.new()}, fn
      %{id: id} = pane, {acc, seen} when is_binary(id) ->
        if MapSet.member?(seen, id) do
          {acc, seen}
        else
          {[pane | acc], MapSet.put(seen, id)}
        end

      _pane, acc ->
        acc
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp reject_registered(panes, registered_panes) do
    registered_ids =
      registered_panes
      |> Enum.map(& &1.id)
      |> MapSet.new()

    Enum.reject(panes, &MapSet.member?(registered_ids, &1.id))
  end

  defp maybe_segment(_key, nil), do: nil
  defp maybe_segment(_key, ""), do: nil
  defp maybe_segment(key, value), do: key <> "=" <> to_string(value)

  defp child_pane_registry(%{child_pane_registry: registry}) when is_map(registry), do: registry
  defp child_pane_registry(_state), do: %{}

  defp apply_cleanup_event(state, %{kind: :child, child_id: child_id}) do
    pane_id = child_pane_key(child_pane_registry(state), child_id)
    remove_panes(state, fn pane -> pane.child_id == child_id or pane.id == pane_id end)
  end

  defp apply_cleanup_event(state, %{kind: :session, session_id: session_id}) do
    remove_panes(state, fn pane -> pane_session_id(pane) == session_id end)
  end

  defp remove_panes(
         %{working: working, completed: completed, open: open, focused: focused} = state,
         predicate
       ) do
    {removed_working, remaining_working} = Enum.split_with(working, predicate)
    {removed_completed, remaining_completed} = Enum.split_with(completed, predicate)

    removed_ids =
      (removed_working ++ removed_completed)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    if MapSet.size(removed_ids) == 0 do
      state
    else
      remaining_open = Enum.reject(open, &MapSet.member?(removed_ids, &1))
      focused = if MapSet.member?(removed_ids, focused), do: nil, else: focused

      %{
        state
        | working: remaining_working,
          completed: remaining_completed,
          open: remaining_open,
          focused: focused
      }
      |> Map.put(:child_pane_registry, prune_registry(child_pane_registry(state), removed_ids))
    end
  end

  defp prune_registry(registry, removed_ids) do
    Enum.reject(registry, fn {_child_id, pane_id} -> MapSet.member?(removed_ids, pane_id) end)
    |> Map.new()
  end

  defp pane_session_id(%{external_ids: external_ids}) when is_map(external_ids) do
    present_runtime_id(external_ids, :session_id) ||
      present_runtime_id(external_ids, "session_id") ||
      present_runtime_id(external_ids, :sessionID) ||
      present_runtime_id(external_ids, "sessionID") ||
      present_runtime_id(external_ids, :sessionId) ||
      present_runtime_id(external_ids, "sessionId")
  end

  defp pane_session_id(_pane), do: nil

  defp cleanup_child_id(event) do
    case cleanup_identifier(event, [
           :child_id,
           :childID,
           :childId,
           "child_id",
           "childID",
           "childId"
         ]) do
      nil -> :error
      child_id -> {:ok, child_id}
    end
  end

  defp cleanup_session_id(event) do
    session_id =
      case cleanup_identifier(event, [
             :session_id,
             :sessionID,
             :sessionId,
             "session_id",
             "sessionID",
             "sessionId"
           ]) do
        nil -> cleanup_identifier(Map.get(event, :external_ids, %{}), [:session_id, "session_id"])
        session_id -> session_id
      end

    case session_id do
      nil -> :error
      session_id -> {:ok, session_id}
    end
  end

  defp cleanup_identifier(event, keys) when is_map(event) do
    keys
    |> Enum.find_value(fn key -> normalize_runtime_id(Map.get(event, key)) end)
  end

  defp cleanup_identifier(_event, _keys), do: nil

  defp existing_pane_id(%{working: working, completed: completed} = state, selected_id) do
    case find_existing_pane(%{state | working: working, completed: completed}, selected_id) do
      %{id: pane_id} when is_binary(pane_id) -> {:ok, pane_id}
      _pane -> :error
    end
  end

  defp find_existing_pane(%{working: working, completed: completed} = state, selected_id)
       when is_list(working) and is_list(completed) and is_binary(selected_id) do
    panes = working ++ completed
    registry = child_pane_registry(state)
    registered_pane_id = Map.get(registry, selected_id)

    Enum.find(panes, &pane_matches?(&1, selected_id, registered_pane_id))
  end

  defp find_existing_pane(_state, _selected_id), do: nil

  defp find_existing_pane_from_options(%{working: working, completed: completed}, options)
       when is_list(working) and is_list(completed) do
    external_ids =
      options
      |> Map.new()
      |> metadata_map(:external_ids, %{})

    reusable_session_pane(working ++ completed, external_ids)
  end

  defp find_existing_pane_from_options(_state, _options), do: nil

  defp pane_matches?(%{id: id}, selected_id, _registered_pane_id) when id == selected_id, do: true

  defp pane_matches?(%{id: id}, _selected_id, registered_pane_id)
       when is_binary(registered_pane_id) and id == registered_pane_id,
       do: true

  defp pane_matches?(%{child_id: child_id}, selected_id, _registered_pane_id)
       when child_id == selected_id,
       do: true

  defp pane_matches?(%{external_ids: external_ids}, selected_id, _registered_pane_id)
       when is_map(external_ids) do
    external_id_matches?(external_ids, selected_id)
  end

  defp pane_matches?(_pane, _selected_id, _registered_pane_id), do: false

  defp external_id_matches?(external_ids, selected_id) when is_map(external_ids) do
    Enum.any?(external_ids, fn {key, value} ->
      cond do
        runtime_id_key?(key) and normalize_runtime_id(value) == selected_id ->
          true

        is_map(value) ->
          external_id_matches?(value, selected_id)

        is_list(value) ->
          Enum.any?(value, &external_id_matches?(&1, selected_id))

        true ->
          false
      end
    end)
  end

  defp external_id_matches?(_external_ids, _selected_id), do: false

  defp reusable_session_pane(panes, external_ids) when is_list(panes) and is_map(external_ids) do
    external_ids
    |> strongest_session_identifiers()
    |> Enum.find_value(fn identifier ->
      Enum.find(panes, &external_id_matches?(Map.get(&1, :external_ids, %{}), identifier))
    end)
  end

  defp reusable_session_pane(_panes, _external_ids), do: nil

  defp reusable_session_pane_for_event(panes, pane) when is_map(pane) do
    if fallback_pane?(pane) or explicit_child_runtime_id?(pane) do
      nil
    else
      reusable_session_pane(panes, pane.external_ids)
    end
  end

  defp reusable_session_pane_for_event(_panes, _pane), do: nil

  defp explicit_child_runtime_id?(%{child_id: child_id, external_ids: external_ids})
       when is_binary(child_id) and is_map(external_ids) do
    present_runtime_id(external_ids, "childID") == child_id or
      present_runtime_id(external_ids, :childID) == child_id or
      present_runtime_id(external_ids, "child_id") == child_id or
      present_runtime_id(external_ids, :child_id) == child_id
  end

  defp explicit_child_runtime_id?(_pane), do: false

  defp strongest_session_identifiers(external_ids) when is_map(external_ids) do
    [
      [
        :native_session_id,
        :nativeSessionID,
        :nativeSessionId,
        "native_session_id",
        "nativeSessionID",
        "nativeSessionId"
      ],
      [:thread_id, :threadID, :threadId, "thread_id", "threadID", "threadId"],
      [
        :input_session_id,
        :inputSessionID,
        :inputSessionId,
        "input_session_id",
        "inputSessionID",
        "inputSessionId"
      ],
      [
        :session_id,
        :sessionID,
        :sessionId,
        :_sessionId,
        "session_id",
        "sessionID",
        "sessionId",
        "_sessionId"
      ]
    ]
    |> Enum.find_value([], fn keys ->
      values = runtime_values_for_keys(external_ids, keys)

      if values == [] do
        nil
      else
        values
      end
    end)
  end

  defp strongest_session_identifiers(_external_ids), do: []

  defp runtime_values_for_keys(external_ids, keys) when is_map(external_ids) and is_list(keys) do
    direct_values =
      keys
      |> Enum.map(&Map.get(external_ids, &1))
      |> Enum.map(&normalize_runtime_id/1)
      |> Enum.reject(&is_nil/1)

    nested_values =
      external_ids
      |> Map.values()
      |> Enum.flat_map(fn
        value when is_map(value) -> runtime_values_for_keys(value, keys)
        values when is_list(values) -> Enum.flat_map(values, &runtime_values_for_keys(&1, keys))
        _value -> []
      end)

    (direct_values ++ nested_values)
    |> Enum.uniq()
  end

  defp runtime_values_for_keys(_external_ids, _keys), do: []

  defp mark_focused_panes(panes, pane_id) do
    Enum.map(panes, fn
      %{id: id, pane_state: pane_state} = pane when is_map(pane_state) ->
        put_in(pane, [:pane_state, :focused?], id == pane_id)

      pane ->
        pane
    end)
  end

  defp focused_pane_map(%{pane_state: pane_state}, _pane_id) when is_map(pane_state) do
    Map.put(pane_state, :focused?, true)
  end

  defp focused_pane_map(_pane, _pane_id), do: %{focused?: true}

  defp normalize_selected_identifier(identifier) do
    case normalize_runtime_id(identifier) do
      nil -> {:error, :invalid_child_session_identifier}
      identifier -> {:ok, identifier}
    end
  end

  defp create_request_child_id("child-session:" <> child_id) do
    case normalize_runtime_id(child_id) do
      nil -> {:error, :invalid_child_session_identifier}
      child_id -> {:ok, child_id}
    end
  end

  defp create_request_child_id(child_id), do: {:ok, child_id}

  defp create_request_pane_id(state, child_id) do
    state
    |> child_pane_registry()
    |> Map.get(child_id, pane_id(child_id))
  end

  defp create_open_request(child_id, identifier, pane_id, options) do
    options = Map.new(options)
    external_ids = metadata_map(options, :external_ids, %{})

    %{
      action: :create_open,
      kind: :child_session_create_open_request,
      child_id: child_id,
      pane_id: pane_id,
      selected_identifier: identifier,
      parent_call_id: metadata_value(options, :parent_call_id),
      runtime_source: metadata_value(options, :runtime_source),
      transport: metadata_value(options, :transport),
      external_ids: Map.put_new(external_ids, "childID", child_id),
      stream_cursor: metadata_map(options, :stream_cursor, %{}),
      pane_state:
        %{
          open?: true,
          focused?: true,
          renderer: :default_child_session
        }
        |> Map.merge(metadata_map(options, :pane_state, %{}))
    }
  end

  defp create_open_request_metadata(request, focused?) do
    %{
      child_id: metadata_value(request, :child_id),
      parent_call_id: metadata_value(request, :parent_call_id),
      runtime_source: metadata_value(request, :runtime_source),
      transport: metadata_value(request, :transport),
      external_ids: metadata_map(request, :external_ids, %{}),
      stream_cursor: metadata_map(request, :stream_cursor, %{}),
      pane_state:
        request
        |> metadata_map(:pane_state, %{})
        |> Map.put(:focused?, focused?)
    }
  end

  defp no_active_child_pane?(focused, open) do
    focused in [nil, ""] and open == []
  end

  defp apply_pane_lifecycle(
         %{working: working, completed: completed, focused: focused, open: open} = state,
         pane,
         lifecycle_type
       ) do
    child_id = registry_child_id(pane.child_id)

    registry =
      state
      |> child_pane_registry()
      |> register_child_id(child_id, pane)

    pane_id = Map.fetch!(registry, child_id)
    pane = %{pane | id: pane_id, child_id: child_id}
    pane_for_insert = merge_existing(working ++ completed, pane)

    {working, completed} =
      if pane.status == :completed or lifecycle_type == :child_pane_completed do
        {
          reject_pane(working, pane_id),
          upsert_pane(completed, %{pane_for_insert | status: :completed}, fn existing ->
            %{merge_pane(existing, pane) | status: :completed}
          end)
        }
      else
        {
          upsert_pane(working, pane_for_insert, fn existing -> merge_pane(existing, pane) end),
          reject_pane(completed, pane_id)
        }
      end

    focused =
      cond do
        lifecycle_type == :child_pane_focused -> pane_id
        get_in(pane, [:pane_state, :focused?]) == true -> pane_id
        is_nil(focused) or focused == "" -> pane_id
        true -> focused
      end

    %{
      state
      | working: mark_focused_panes(working, focused),
        completed: mark_focused_panes(completed, focused),
        focused: focused,
        open: append_once(open, pane_id)
    }
    |> Map.put(:child_pane_registry, registry)
  end

  defp restore_relationship(state, relationship) when is_map(relationship) do
    child_id = registry_child_id(relationship.child_id)
    relationship = Map.put(relationship, :child_id, child_id)
    state = seed_existing_relationship_registry(state, relationship)

    event =
      relationship
      |> relationship_pane_event()
      |> drop_replayed_stream_entries(state, relationship)

    {:ok, apply_event(state, event)}
  end

  defp restore_relationship(_state, _relationship),
    do: {:error, :invalid_relationship_recovery_index}

  defp seed_existing_relationship_registry(
         %{working: working, completed: completed} = state,
         relationship
       ) do
    registry = child_pane_registry(state)

    if Map.has_key?(registry, relationship.child_id) do
      state
    else
      case existing_relationship_pane(working ++ completed, relationship) do
        %{id: pane_id} when is_binary(pane_id) ->
          Map.put(state, :child_pane_registry, Map.put(registry, relationship.child_id, pane_id))

        _pane ->
          state
      end
    end
  end

  defp existing_relationship_pane(panes, relationship) when is_list(panes) do
    Enum.find(panes, &same_relationship?(&1, relationship))
  end

  defp same_relationship?(%{child_id: child_id, parent_call_id: parent_call_id}, relationship)
       when child_id == relationship.child_id and parent_call_id == relationship.parent_call_id,
       do: true

  defp same_relationship?(
         %{external_ids: external_ids, parent_call_id: parent_call_id},
         relationship
       )
       when is_map(external_ids) and parent_call_id == relationship.parent_call_id do
    relationship.external_ids
    |> strongest_session_identifiers()
    |> Enum.any?(&external_id_matches?(external_ids, &1))
  end

  defp same_relationship?(_pane, _relationship), do: false

  defp relationship_pane_event(relationship) do
    %{
      type: relationship_status_type(relationship.status),
      pane_id: relationship.pane_id,
      child_id: relationship.child_id,
      parent_call_id: relationship.parent_call_id,
      runtime_source: relationship.runtime_source,
      transport: relationship.transport,
      external_ids: relationship.external_ids,
      stream_cursor: relationship.stream_cursor,
      pane_state:
        %{
          last_event_seq: relationship.latest_event_seq,
          last_acknowledged_stream_cursor: relationship.acknowledged_stream_cursor
        }
        |> Map.merge(relationship.pane_state || %{}),
      created_at_ms: relationship.created_at_ms,
      updated_at_ms: relationship.updated_at_ms || relationship.occurred_at_ms,
      occurred_at_ms: relationship.occurred_at_ms,
      status: relationship.status || :working
    }
  end

  defp relationship_status_type(:completed), do: :child_pane_completed
  defp relationship_status_type(_status), do: :child_pane_registered

  defp drop_replayed_stream_entries(event, state, relationship) do
    existing_entries =
      state
      |> relationship_pane(relationship)
      |> stream_entries()

    incoming_entries =
      case get_in(event, [:pane_state, :stream_entries]) do
        entries when is_list(entries) -> Enum.map(entries, &normalize_stream_entry/1)
        _entries -> []
      end

    if incoming_entries != [] and all_stream_entries_replayed?(incoming_entries, existing_entries) do
      update_in(event, [:pane_state], &Map.delete(&1, :stream_entries))
    else
      event
    end
  end

  defp replayed_at_or_before_acknowledged_cursor?(pane, existing_pane) do
    with %{pane_state: existing_pane_state} when is_map(existing_pane_state) <- existing_pane,
         cursor when is_map(cursor) <- acknowledged_stream_cursor(existing_pane_state),
         ack_seq when is_integer(ack_seq) <- cursor_event_seq(cursor),
         event_seq when is_integer(event_seq) <- pane_event_seq(pane) do
      event_seq <= ack_seq
    else
      _value -> false
    end
  end

  defp surface_replay_cursor_gap(pane, existing_pane, pane_id) do
    case replay_cursor_gap(pane, existing_pane, pane_id) do
      nil ->
        pane

      gap ->
        put_in(pane, [:pane_state, :replay_gap_error], gap)
    end
  end

  defp replay_cursor_gap(pane, existing_pane, pane_id) do
    with %{pane_state: existing_pane_state} when is_map(existing_pane_state) <- existing_pane,
         baseline_seq when is_integer(baseline_seq) <- replay_gap_baseline_seq(existing_pane),
         event_seq when is_integer(event_seq) <- pane_event_seq(pane),
         true <- event_seq > baseline_seq + 1 do
      missing_from = baseline_seq + 1
      missing_to = event_seq - 1

      %{
        type: :recoverable_stream_gap,
        pane_id: pane_id,
        child_id: pane.child_id,
        expected_event_seq: missing_from,
        received_event_seq: event_seq,
        missing_event_seq_range: %{from: missing_from, to: missing_to},
        missing_event_seqs: Enum.to_list(missing_from..missing_to//1),
        acknowledged_stream_cursor: acknowledged_stream_cursor(existing_pane_state),
        recovery: :resume_from_acknowledged_stream_cursor
      }
    else
      _value -> nil
    end
  end

  defp replay_gap_baseline_seq(%{pane_state: pane_state} = pane) when is_map(pane_state) do
    cursor_event_seq(acknowledged_stream_cursor(pane_state)) || pane_event_seq(pane)
  end

  defp replay_gap_baseline_seq(_pane), do: nil

  defp pane_event_seq(pane) do
    cursor_event_seq(Map.get(pane, :stream_cursor)) ||
      cursor_event_seq(Map.get(pane, :pane_state))
  end

  defp cursor_event_seq(cursor) when is_map(cursor) do
    case Map.get(cursor, :event_seq) || Map.get(cursor, "event_seq") do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _value -> nil
    end
  end

  defp cursor_event_seq(_cursor), do: nil

  defp acknowledged_stream_cursor(pane_state) when is_map(pane_state) do
    Map.get(pane_state, :last_acknowledged_stream_cursor) ||
      Map.get(pane_state, "last_acknowledged_stream_cursor") ||
      Map.get(pane_state, :acknowledged_stream_cursor) ||
      Map.get(pane_state, "acknowledged_stream_cursor")
  end

  defp acknowledged_stream_cursor(_pane_state), do: nil

  defp replay_gap_error(%{pane_state: pane_state}) when is_map(pane_state) do
    Map.get(pane_state, :replay_gap_error) || Map.get(pane_state, "replay_gap_error")
  end

  defp replay_gap_error(_pane), do: nil

  defp replay_gap_segment(%{missing_event_seq_range: %{from: from, to: to}}),
    do: "gap=#{from}..#{to}"

  defp replay_gap_segment(%{"missing_event_seq_range" => %{"from" => from, "to" => to}}),
    do: "gap=#{from}..#{to}"

  defp replay_gap_segment(_gap), do: nil

  defp relationship_pane(%{working: working, completed: completed}, relationship)
       when is_list(working) and is_list(completed) do
    existing_relationship_pane(working ++ completed, relationship)
  end

  defp relationship_pane(_state, _relationship), do: nil

  defp all_stream_entries_replayed?(incoming_entries, existing_entries) do
    existing_keys =
      existing_entries
      |> Enum.map(&stream_entry_replay_key/1)
      |> MapSet.new()

    Enum.all?(incoming_entries, &MapSet.member?(existing_keys, stream_entry_replay_key(&1)))
  end

  defp stream_entry_replay_key(entry) when is_map(entry) do
    {
      Map.get(entry, :event_seq) || Map.get(entry, "event_seq"),
      Map.get(entry, :runtime_seq) || Map.get(entry, "runtime_seq"),
      Map.get(entry, :token) || Map.get(entry, "token"),
      Map.get(entry, :delta) || Map.get(entry, "delta"),
      Map.get(entry, :content) || Map.get(entry, "content")
    }
  end

  defp stream_entry_replay_key(entry), do: entry

  defp metadata_string(metadata, key) do
    value =
      metadata
      |> metadata_value(key)
      |> normalize_runtime_id()

    case value do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp metadata_string_any(metadata, keys) when is_list(keys) do
    Enum.find_value(keys, :error, fn key ->
      case metadata_string(metadata, key) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end)
  end

  defp metadata_transport(metadata) do
    case metadata_value(metadata, :transport) do
      transport when transport in [:stdio, :streamable_http, :sse] -> {:ok, transport}
      "stdio" -> {:ok, :stdio}
      "streamable_http" -> {:ok, :streamable_http}
      "sse" -> {:ok, :sse}
      _transport -> :error
    end
  end

  defp metadata_integer(metadata, key) do
    case metadata_value(metadata, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _value -> nil
    end
  end

  defp parse_integer(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _parse_error -> nil
    end
  end

  defp metadata_map(metadata, key, default) do
    case metadata_value(metadata, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp metadata_acknowledged_stream_cursor(metadata) do
    case metadata_value(metadata, :last_acknowledged_stream_cursor) ||
           metadata_value(metadata, :acknowledged_stream_cursor) do
      cursor when is_map(cursor) -> cursor
      _cursor -> nil
    end
  end

  defp metadata_pane_projection_state(metadata) do
    metadata
    |> metadata_map(:pane_state, %{})
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, pane_state_key(key), pane_state_value(key, value))
    end)
  end

  defp pane_state_key("open?"), do: :open?
  defp pane_state_key("focused?"), do: :focused?
  defp pane_state_key("renderer"), do: :renderer
  defp pane_state_key("last_event_seq"), do: :last_event_seq
  defp pane_state_key("last_acknowledged_stream_cursor"), do: :last_acknowledged_stream_cursor
  defp pane_state_key("acknowledged_stream_cursor"), do: :acknowledged_stream_cursor
  defp pane_state_key("stream_entries"), do: :stream_entries
  defp pane_state_key("title"), do: :title
  defp pane_state_key(key), do: key

  defp pane_state_value("stream_entries", entries) when is_list(entries) do
    Enum.map(entries, &normalize_stream_entry/1)
  end

  defp pane_state_value(:stream_entries, entries) when is_list(entries) do
    Enum.map(entries, &normalize_stream_entry/1)
  end

  defp pane_state_value("renderer", renderer), do: renderer_value(renderer)
  defp pane_state_value(:renderer, renderer), do: renderer_value(renderer)
  defp pane_state_value(_key, value), do: value

  defp renderer_value("default_child_session"), do: :default_child_session
  defp renderer_value("trusted_plugin_renderer"), do: :trusted_plugin_renderer
  defp renderer_value(renderer), do: renderer

  defp normalize_stream_entry(entry) when is_map(entry) do
    Enum.reduce(entry, %{}, fn {key, value}, acc ->
      Map.put(acc, stream_entry_key(key), value)
    end)
  end

  defp normalize_stream_entry(entry), do: entry

  defp stream_entry_key("event_seq"), do: :event_seq
  defp stream_entry_key("runtime_seq"), do: :runtime_seq
  defp stream_entry_key("occurred_at_ms"), do: :occurred_at_ms
  defp stream_entry_key("token"), do: :token
  defp stream_entry_key("payload"), do: :payload
  defp stream_entry_key("child_event_id"), do: :child_event_id
  defp stream_entry_key(key), do: key

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp pane_lifecycle_type(event) do
    case metadata_value(event, :type) || metadata_value(event, :event_type) do
      type when is_atom(type) ->
        if MapSet.member?(@pane_lifecycle_types, type), do: {:ok, type}, else: :error

      type when is_binary(type) ->
        normalized = String.trim(type)

        Enum.find_value(@pane_lifecycle_types, :error, fn lifecycle_type ->
          if Atom.to_string(lifecycle_type) == normalized, do: {:ok, lifecycle_type}
        end)

      _type ->
        :error
    end
  end

  defp metadata_status(event, lifecycle_type) do
    case metadata_value(event, :status) do
      status when status in [:working, :completed] -> status
      "working" -> :working
      "completed" -> :completed
      _status when lifecycle_type == :child_pane_completed -> :completed
      _status -> :working
    end
  end

  defp metadata_pane_state(metadata, nil) do
    %{
      open?: true,
      focused?: false,
      renderer: :default_child_session
    }
    |> Map.merge(metadata_map(metadata, :pane_state, %{}))
  end

  defp metadata_pane_state(metadata, _existing_pane) do
    metadata_map(metadata, :pane_state, %{})
  end

  defp registry_child_id(child_id) do
    case String.trim(child_id) do
      "" -> child_id
      trimmed -> trimmed
    end
  end

  defp child_runtime_id(event) do
    event =
      event
      |> Map.put(:external_ids, external_ids_map(event))
      |> Map.put(:fallback_runtime_metadata, fallback_runtime_metadata(event))

    case ChildSessionCreationParser.extract(event) do
      {:ok, %{child_id: child_id, source: {:fallback, source}}} ->
        {:ok, {child_id, {:fallback, source}}}

      {:ok, %{child_id: child_id, source: :pane_key}} ->
        {:ok, {child_id, :pane_key}}

      {:ok, %{child_id: child_id}} ->
        {:ok, {child_id, :runtime_child_id}}

      {:unresolved, _reason} ->
        :error

      :ignore ->
        :error
    end
  end

  defp required_string(event, key) do
    case Map.get(event, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp required_transport(%{transport: transport})
       when transport in [:stdio, :streamable_http, :sse],
       do: {:ok, transport}

  defp required_transport(_event), do: :error

  defp child_pane_event?(event) do
    Map.get(event, :type) in [:parent_call_started, :parent_call_event, :parent_call_result]
  end

  defp external_ids(event, child_id, :runtime_child_id) do
    event
    |> external_ids_map()
    |> Map.put_new("childID", child_id)
  end

  defp external_ids(event, child_id, :pane_key) do
    event
    |> external_ids_map()
    |> Map.put_new("pane_key", pane_id(child_id))
    |> Map.put_new("child_id", child_id)
  end

  defp external_ids(event, child_id, {:fallback, source}) do
    event
    |> external_ids_map()
    |> Map.put_new("fallback_child_id", child_id)
    |> Map.put_new("fallback_child_id_source", Atom.to_string(source))
    |> Map.put_new("child_id", child_id)
  end

  defp stabilize_fallback_child_id(existing_panes, pane) do
    if fallback_pane?(pane) do
      case Enum.find(existing_panes, &same_fallback_runtime?(&1, pane)) do
        nil -> pane
        existing -> reuse_fallback_child_id(pane, existing)
      end
    else
      pane
    end
  end

  defp fallback_pane?(pane) do
    is_map(pane.external_ids) and Map.has_key?(pane.external_ids, "fallback_child_id")
  end

  defp same_fallback_runtime?(existing, pane) do
    fallback_pane?(existing) and
      not conflicting_same_source_fallback?(existing, pane) and
      Enum.any?(runtime_identity_keys(), fn key ->
        present_runtime_id(existing.external_ids, key) != nil and
          present_runtime_id(existing.external_ids, key) ==
            present_runtime_id(pane.external_ids, key)
      end)
  end

  defp conflicting_same_source_fallback?(existing, pane) do
    existing_source = Map.get(existing.external_ids, "fallback_child_id_source")
    pane_source = Map.get(pane.external_ids, "fallback_child_id_source")
    existing_id = Map.get(existing.external_ids, "fallback_child_id")
    pane_id = Map.get(pane.external_ids, "fallback_child_id")

    existing_source != nil and existing_source == pane_source and
      existing_id != nil and pane_id != nil and existing_id != pane_id
  end

  defp reuse_fallback_child_id(pane, existing) do
    child_id = existing.child_id
    source = Map.get(existing.external_ids, "fallback_child_id_source")

    %{
      pane
      | id: existing.id,
        child_id: child_id,
        external_ids:
          pane.external_ids
          |> Map.put("fallback_child_id", child_id)
          |> Map.put("child_id", child_id)
          |> maybe_put_fallback_source(source),
        stream_cursor: Map.put(pane.stream_cursor, :child_id, child_id)
    }
  end

  defp maybe_put_fallback_source(external_ids, nil), do: external_ids

  defp maybe_put_fallback_source(external_ids, source) do
    Map.put(external_ids, "fallback_child_id_source", source)
  end

  defp pane_id(child_id), do: "child-session:" <> child_id

  defp external_ids_map(event) do
    event
    |> runtime_event_external_ids()
    |> Map.merge(valid_runtime_external_ids(stdout_jsonl_external_ids(event)))
    |> Map.merge(valid_runtime_external_ids(primary_external_ids(event)))
  end

  defp primary_external_ids(event) do
    case Map.get(event, :external_ids) || Map.get(event, "external_ids") do
      external_ids when is_map(external_ids) -> external_ids
      _ -> %{}
    end
  end

  defp runtime_event_external_ids(event) do
    event
    |> RuntimeEventParser.extract_external_ids()
    |> valid_runtime_external_ids()
  end

  defp fallback_runtime_metadata(event) do
    candidates = %{
      primary: valid_runtime_external_ids(primary_external_ids(event)),
      stdout_jsonl: valid_runtime_external_ids(stdout_jsonl_external_ids(event)),
      runtime_event: runtime_event_external_ids(event)
    }

    @fallback_metadata_precedence
    |> Enum.map(&Map.fetch!(candidates, &1))
    |> Enum.find(%{}, &fallback_runtime_metadata?/1)
  end

  defp fallback_runtime_metadata?(external_ids) do
    Enum.any?([:execution_id, :job_id, :native_session_id, :thread_id, :session_id], fn key ->
      Map.has_key?(external_ids, key) or Map.has_key?(external_ids, Atom.to_string(key))
    end)
  end

  defp stdout_jsonl_external_ids(event) do
    event
    |> stdout_jsonl_candidates()
    |> Enum.reduce(%{}, fn candidate, acc ->
      Map.merge(acc, stdout_jsonl_candidate_external_ids(candidate))
    end)
  end

  defp stdout_jsonl_candidates(event) do
    [
      Map.get(event, :stdout_jsonl),
      Map.get(event, "stdout_jsonl"),
      Map.get(event, :stdout),
      Map.get(event, "stdout"),
      Map.get(event, :stdout_jsonl_records),
      Map.get(event, "stdout_jsonl_records")
    ]
    |> Enum.flat_map(fn
      nil -> []
      candidates when is_list(candidates) -> candidates
      candidate -> [candidate]
    end)
  end

  defp stdout_jsonl_candidate_external_ids(candidate) when is_binary(candidate) do
    candidate
    |> StdoutJsonlParser.parse()
    |> stdout_jsonl_candidate_external_ids()
  end

  defp stdout_jsonl_candidate_external_ids(candidate) when is_map(candidate) do
    StdoutJsonlParser.extract_codex_external_ids(candidate)
  end

  defp stdout_jsonl_candidate_external_ids(candidates) when is_list(candidates) do
    Enum.reduce(candidates, %{}, fn candidate, acc ->
      Map.merge(acc, stdout_jsonl_candidate_external_ids(candidate))
    end)
  end

  defp stdout_jsonl_candidate_external_ids(_candidate), do: %{}

  defp valid_runtime_external_ids(external_ids) when is_map(external_ids) do
    Enum.reduce(external_ids, %{}, fn {key, value}, acc ->
      if runtime_id_key?(key) do
        case normalize_runtime_id(value) do
          nil -> acc
          normalized -> Map.put(acc, key, normalized)
        end
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp valid_runtime_external_ids(_external_ids), do: %{}

  defp runtime_id_key?(key) do
    key in runtime_identity_keys()
  end

  defp runtime_identity_keys do
    [
      :native_session_id,
      :nativeSessionID,
      :nativeSessionId,
      "native_session_id",
      "nativeSessionID",
      "nativeSessionId",
      :execution_id,
      :executionID,
      :executionId,
      "execution_id",
      "executionID",
      "executionId",
      :lineage_id,
      :lineageID,
      :lineageId,
      "lineage_id",
      "lineageID",
      "lineageId",
      :job_id,
      :jobID,
      :jobId,
      "job_id",
      "jobID",
      "jobId",
      :call_id,
      :callID,
      :callId,
      :input_call_id,
      :inputCallID,
      :inputCallId,
      "call_id",
      "callID",
      "callId",
      "input_call_id",
      "inputCallID",
      "inputCallId",
      :childID,
      :childId,
      :child_id,
      "childID",
      "childId",
      "child_id",
      :session_id,
      :sessionID,
      :sessionId,
      :_sessionId,
      "session_id",
      "sessionID",
      "sessionId",
      "_sessionId",
      :thread_id,
      :threadID,
      :threadId,
      "thread_id",
      "threadID",
      "threadId"
    ]
  end

  defp present_runtime_id(external_ids, key) do
    external_ids
    |> Map.get(key)
    |> normalize_runtime_id()
  end

  defp normalize_runtime_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_runtime_id(_value), do: nil

  defp merge_existing(panes, pane) do
    case Enum.find(panes, &(&1.id == pane.id)) do
      nil ->
        pane

      existing ->
        merge_pane(existing, pane)
    end
  end

  defp merge_pane(existing, pane) do
    existing
    |> Map.merge(%{
      status: :working,
      child_id: pane.child_id,
      updated_at_ms: pane.updated_at_ms,
      stream_cursor: Map.merge(existing.stream_cursor || %{}, pane.stream_cursor || %{}),
      external_ids: Map.merge(existing.external_ids, pane.external_ids)
    })
    |> Map.put(
      :pane_state,
      existing.pane_state
      |> Map.merge(mergeable_pane_state(existing.pane_state, pane.pane_state))
      |> Map.put(
        :stream_entries,
        dedupe_stream_entries(stream_entries(existing) ++ stream_entries(pane))
      )
    )
  end

  defp apply_child_pane_updates(pane, updates) do
    transport = metadata_update_transport(updates, pane.transport)

    pane
    |> Map.merge(%{
      status: metadata_update_status(updates, pane.status),
      runtime_source: metadata_update_string(updates, :runtime_source, pane.runtime_source),
      transport: transport,
      external_ids: Map.merge(pane.external_ids, metadata_map(updates, :external_ids, %{})),
      stream_cursor:
        pane.stream_cursor
        |> Map.merge(metadata_map(updates, :stream_cursor, %{}))
        |> Map.put(:transport, transport)
        |> Map.put(:child_id, pane.child_id),
      pane_state: Map.merge(pane.pane_state, metadata_map(updates, :pane_state, %{})),
      updated_at_ms: metadata_integer(updates, :updated_at_ms) || pane.updated_at_ms
    })
    |> Map.put(:id, pane.id)
    |> Map.put(:kind, :child_session)
    |> Map.put(:child_id, pane.child_id)
    |> Map.put(:parent_call_id, pane.parent_call_id)
    |> Map.put(:created_at_ms, pane.created_at_ms)
  end

  defp metadata_update_string(updates, key, default) do
    case metadata_value(updates, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          value -> value
        end

      _value ->
        default
    end
  end

  defp metadata_update_transport(updates, default) do
    case metadata_transport(updates) do
      {:ok, transport} -> transport
      :error -> default
    end
  end

  defp metadata_update_status(updates, default) do
    case metadata_value(updates, :status) do
      status when status in [:working, :completed] -> status
      "working" -> :working
      "completed" -> :completed
      _status -> default
    end
  end

  defp dedupe_stream_entries(entries) do
    entries
    |> Enum.reduce({[], MapSet.new()}, fn entry, {acc, seen} ->
      key = stream_entry_dedupe_key(entry)

      if MapSet.member?(seen, key) do
        {acc, seen}
      else
        {[entry | acc], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp stream_entry_dedupe_key(entry) when is_map(entry) do
    case Map.get(entry, :child_event_id) || Map.get(entry, "child_event_id") do
      child_event_id when is_binary(child_event_id) and child_event_id != "" ->
        {:child_event_id, child_event_id}

      _child_event_id ->
        {:replay, stream_entry_replay_key(entry)}
    end
  end

  defp stream_entry_dedupe_key(entry), do: {:replay, stream_entry_replay_key(entry)}

  defp mergeable_pane_state(existing_pane_state, pane_state) do
    pane_state
    |> Map.delete(:stream_entries)
    |> maybe_drop_default_renderer(existing_pane_state)
    |> maybe_drop_nil_ack_cursor(existing_pane_state)
  end

  defp maybe_drop_default_renderer(
         %{renderer: :default_child_session} = pane_state,
         existing_pane_state
       )
       when is_map_key(existing_pane_state, :renderer) do
    Map.delete(pane_state, :renderer)
  end

  defp maybe_drop_default_renderer(pane_state, _existing_pane_state), do: pane_state

  defp maybe_drop_nil_ack_cursor(
         %{last_acknowledged_stream_cursor: nil} = pane_state,
         existing_pane_state
       )
       when is_map_key(existing_pane_state, :last_acknowledged_stream_cursor) do
    Map.delete(pane_state, :last_acknowledged_stream_cursor)
  end

  defp maybe_drop_nil_ack_cursor(pane_state, _existing_pane_state), do: pane_state

  defp reject_pane(panes, pane_id), do: Enum.reject(panes, &(&1.id == pane_id))

  defp replace_pane(panes, pane_id, updated_pane) do
    Enum.map(panes, fn
      %{id: ^pane_id} -> updated_pane
      pane -> pane
    end)
  end

  defp upsert_pane([], pane, _update), do: [pane]

  defp upsert_pane([%{id: id} = existing | rest], %{id: id}, update) do
    [update.(existing) | rest]
  end

  defp upsert_pane([pane | rest], new_pane, update) do
    [pane | upsert_pane(rest, new_pane, update)]
  end

  defp append_once(values, value) do
    if value in values do
      values
    else
      values ++ [value]
    end
  end

  defp stream_cursor(event, transport, event_seq, child_id) do
    event
    |> upstream_stream_cursor()
    |> Map.merge(%{
      transport: transport,
      event_seq: event_seq,
      child_id: child_id
    })
  end

  defp upstream_stream_cursor(event) do
    event
    |> stream_cursor_candidates()
    |> Enum.find_value(%{}, &cursor_from_payload/1)
  end

  defp stream_cursor_candidates(event) do
    [
      event,
      Map.get(event, :params),
      Map.get(event, "params"),
      Map.get(event, :notification),
      Map.get(event, "notification"),
      get_path(event, [:notification, "params"]),
      get_path(event, [:notification, :params]),
      get_path(event, ["notification", "params"]),
      get_path(event, ["notification", :params]),
      Map.get(event, :result),
      Map.get(event, "result"),
      get_path(event, [:result, "params"]),
      get_path(event, [:result, :params]),
      get_path(event, ["result", "params"]),
      get_path(event, ["result", :params]),
      Map.get(event, :raw_event),
      Map.get(event, "raw_event"),
      get_path(event, [:raw_event, "data"]),
      get_path(event, [:raw_event, :data]),
      get_path(event, ["raw_event", "data"]),
      get_path(event, ["raw_event", :data]),
      get_path(event, [:raw_event, "data", "params"]),
      get_path(event, [:raw_event, :data, :params]),
      get_path(event, ["raw_event", "data", "params"]),
      get_path(event, ["raw_event", :data, :params]),
      get_path(event, [:raw_event, "data", "result"]),
      get_path(event, [:raw_event, :data, :result]),
      get_path(event, ["raw_event", "data", "result"]),
      get_path(event, ["raw_event", :data, :result])
    ]
    |> Enum.filter(&is_map/1)
  end

  defp cursor_from_payload(payload) when is_map(payload) do
    payload
    |> get_in_any([
      "stream_cursor",
      :stream_cursor,
      "streamCursor",
      :streamCursor,
      "cursor",
      :cursor
    ])
    |> normalize_stream_cursor()
  end

  defp cursor_from_payload(_payload), do: nil

  defp normalize_stream_cursor(cursor) when is_map(cursor), do: cursor
  defp normalize_stream_cursor(cursor) when is_binary(cursor), do: %{cursor: cursor}
  defp normalize_stream_cursor(cursor) when is_integer(cursor), do: %{cursor: cursor}
  defp normalize_stream_cursor(_cursor), do: nil

  defp stream_entries_for_event(event, event_seq, occurred_at_ms) do
    payload = stream_payload(event)

    if payload == %{} do
      []
    else
      [stream_entry(event, event_seq, occurred_at_ms, payload)]
    end
  end

  defp stream_entry(event, event_seq, occurred_at_ms, payload) do
    stream_entry = %{
      event_seq: event_seq,
      runtime_seq: runtime_seq(payload),
      type: Map.get(event, :type),
      token: string_payload_value(payload, "token"),
      delta: string_payload_value(payload, "delta"),
      content: string_payload_value(payload, "content"),
      media_placeholders: media_placeholders(payload),
      payload: payload,
      occurred_at_ms: occurred_at_ms
    }

    Map.put(stream_entry, :child_event_id, child_event_id(event, stream_entry))
  end

  defp child_event_id(event, stream_entry) do
    case Map.get(event, :child_event_id) || Map.get(event, "child_event_id") do
      child_event_id when is_binary(child_event_id) and child_event_id != "" ->
        child_event_id

      _child_event_id ->
        event
        |> Map.put_new(:runtime_seq, Map.get(stream_entry, :runtime_seq))
        |> Map.put_new(:payload, Map.get(stream_entry, :payload))
        |> Journal.child_event_identity()
        |> case do
          {:ok, child_event_id} -> child_event_id
          {:error, _reason} -> nil
        end
    end
  end

  defp stream_payload(event) do
    candidates = stream_payload_candidates(event)

    Enum.find(candidates, &stream_payload?/1) ||
      cursorless_opencode_stream_payload(event, candidates) ||
      %{}
  end

  defp cursorless_opencode_stream_payload(event, candidates) do
    if cursorless_opencode_stream_event?(event) do
      Enum.find(candidates, &direct_child_stream_payload?/1) ||
        Enum.find(candidates, &child_stream_payload?/1)
    end
  end

  defp cursorless_opencode_stream_event?(event) do
    Map.get(event, :type) == :parent_call_event and
      Map.get(event, :runtime_source) == "opencode"
  end

  defp child_stream_payload?(payload) when is_map(payload) do
    ChildSessionCreationParser.extract_child_id(payload) != :ignore
  end

  defp child_stream_payload?(_payload), do: false

  defp direct_child_stream_payload?(payload) when is_map(payload) do
    present?(Map.get(payload, "childID")) or
      present?(Map.get(payload, :childID)) or
      present?(Map.get(payload, "child_id")) or
      present?(Map.get(payload, :child_id))
  end

  defp direct_child_stream_payload?(_payload), do: false

  defp stream_payload_candidates(event) do
    [
      Map.get(event, :params),
      Map.get(event, "params"),
      Map.get(event, :notification),
      Map.get(event, "notification"),
      get_path(event, [:notification, "params"]),
      get_path(event, [:notification, :params]),
      get_path(event, ["notification", "params"]),
      get_path(event, ["notification", :params]),
      Map.get(event, :result),
      Map.get(event, "result"),
      get_path(event, [:result, "params"]),
      get_path(event, [:result, :params]),
      get_path(event, ["result", "params"]),
      get_path(event, ["result", :params]),
      Map.get(event, :raw_event),
      Map.get(event, "raw_event"),
      get_path(event, [:raw_event, "data"]),
      get_path(event, [:raw_event, :data]),
      get_path(event, ["raw_event", "data"]),
      get_path(event, ["raw_event", :data]),
      get_path(event, [:raw_event, "data", "params"]),
      get_path(event, [:raw_event, :data, :params]),
      get_path(event, ["raw_event", "data", "params"]),
      get_path(event, ["raw_event", :data, :params]),
      get_path(event, [:raw_event, "data", "result"]),
      get_path(event, [:raw_event, :data, :result]),
      get_path(event, ["raw_event", "data", "result"]),
      get_path(event, ["raw_event", :data, :result])
    ]
    |> Enum.filter(&is_map/1)
  end

  defp stream_payload?(payload) when is_map(payload) do
    [
      "seq",
      :seq,
      "event_seq",
      :event_seq,
      "token",
      :token,
      "delta",
      :delta,
      "content",
      :content
    ]
    |> Enum.any?(fn key -> present?(Map.get(payload, key)) end)
  end

  defp stream_payload?(_payload), do: false

  defp runtime_seq(payload) do
    payload
    |> get_in_any(["seq", :seq, "event_seq", :event_seq])
    |> integer_or_nil()
  end

  defp string_payload_value(payload, key) do
    payload
    |> get_in_any([key, String.to_atom(key)])
    |> string_or_nil()
  end

  defp media_placeholders(payload) when is_map(payload) do
    payload
    |> media_items()
    |> Enum.with_index(1)
    |> Enum.map(fn {_item, index} -> "[Image ##{index}]" end)
  end

  defp media_placeholders(_payload), do: []

  defp media_items(payload) when is_map(payload) do
    [
      get_in_any(payload, ["images", :images]),
      get_in_any(payload, ["image", :image]),
      get_in_any(payload, ["attachments", :attachments]),
      get_in_any(payload, ["media", :media])
    ]
    |> List.flatten()
    |> Enum.filter(&image_like?/1)
  end

  defp image_like?(%{} = item) do
    type = get_in_any(item, ["type", :type, "mime_type", :mime_type, "mimeType", :mimeType])

    src =
      get_in_any(item, [
        "url",
        :url,
        "data",
        :data,
        "source",
        :source,
        "path",
        :path,
        "base64",
        :base64
      ])

    image_type?(type) or present?(src)
  end

  defp image_like?(value) when is_binary(value), do: present?(value)
  defp image_like?(_value), do: false

  defp image_type?(type) when is_binary(type), do: String.starts_with?(type, "image")
  defp image_type?(_type), do: false

  defp get_in_any(payload, keys) when is_map(payload) do
    Enum.find_value(keys, fn key -> Map.get(payload, key) end)
  end

  defp get_in_any(_payload, _keys), do: nil

  defp get_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      case acc do
        map when is_map(map) -> {:cont, Map.get(map, key)}
        _other -> {:halt, nil}
      end
    end)
  end

  defp get_path(_payload, _path), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp string_or_nil(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true
end
