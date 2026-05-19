defmodule Ourocode.Dashboard.ParentMcpPane do
  @moduledoc """
  Live parent MCP call pane projection.

  Transports and normalizers emit journal-ready parent lifecycle events. This
  module keeps the dashboard projection pure and recoverable by applying those
  events to data-only pane state.
  """

  @terminal_types MapSet.new([
                    :parent_call_result,
                    :parent_call_failed,
                    :parent_call_write_failed,
                    :parent_call_unmatched_result,
                    :transport_decode_failed,
                    :transport_exited
                  ])

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
        %{working: working, completed: completed, focused: focused, open: open} = state,
        event
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(event) do
    case from_cleanup_event(event) do
      {:ok, cleanup} ->
        apply_cleanup_event(state, cleanup)

      :ignore ->
        apply_lifecycle_event(state, event, focused)
    end
  end

  defp apply_lifecycle_event(
         %{working: working, completed: completed, open: open} = state,
         event,
         focused
       ) do
    case from_lifecycle_event(event) do
      {:ok, pane} ->
        pane_id = pane.id

        {working, completed} =
          if terminal?(event) do
            completed_pane = merge_existing(working ++ completed, pane)

            {
              reject_pane(working, pane_id),
              upsert_pane(completed, completed_pane)
            }
          else
            {
              upsert_pane(working, pane),
              reject_pane(completed, pane_id)
            }
          end

        %{
          state
          | working: working,
            completed: completed,
            focused: focused || pane_id,
            open: append_once(open, pane_id)
        }

      :ignore ->
        state
    end
  end

  @doc """
  Registers a parent MCP pane directly from runtime metadata.

  This is the state-model creation entry point for callers that already have a
  trusted parent call identity. The generated pane ID is stable for the parent
  call, and repeat registrations update the same first-class pane entry.
  """
  @spec register_parent_pane(pane_state(), parent_pane_metadata()) ::
          {:ok, pane_state()} | {:error, :invalid_parent_pane_metadata}
  def register_parent_pane(
        %{working: working, completed: completed, focused: focused, open: open} = state,
        metadata
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(metadata) do
    with {:ok, parent_call_id} <- metadata_string(metadata, :parent_call_id),
         {:ok, runtime_source} <- metadata_string(metadata, :runtime_source),
         {:ok, transport} <- metadata_transport(metadata) do
      now = metadata_integer(metadata, :updated_at_ms) || System.system_time(:millisecond)
      created_at_ms = metadata_integer(metadata, :created_at_ms) || now
      pane_id = pane_id(parent_call_id)

      pane = %{
        id: pane_id,
        kind: :parent_mcp_call,
        status: :starting,
        parent_call_id: parent_call_id,
        runtime_source: runtime_source,
        transport: transport,
        external_ids: metadata_map(metadata, :external_ids, %{}),
        request_id: metadata_string_or_nil(metadata, :request_id),
        method: metadata_string_or_nil(metadata, :method),
        params: metadata_value(metadata, :params),
        stream_cursor:
          metadata
          |> metadata_map(:stream_cursor, %{})
          |> Map.merge(%{transport: transport, parent_call_id: parent_call_id}),
        pane_state:
          %{
            open?: true,
            focused?: false,
            renderer: :default_parent_mcp,
            lifecycle_type: :parent_pane_registered,
            event_count: 0,
            notification_count: 0
          }
          |> Map.merge(metadata_map(metadata, :pane_state, %{})),
        created_at_ms: created_at_ms,
        updated_at_ms: now
      }

      {:ok,
       %{
         state
         | working: upsert_pane(working, merge_existing(working ++ completed, pane)),
           completed: reject_pane(completed, pane_id),
           focused: focused || pane_id,
           open: append_once(open, pane_id)
       }}
    else
      _error -> {:error, :invalid_parent_pane_metadata}
    end
  end

  def register_parent_pane(_state, _metadata), do: {:error, :invalid_parent_pane_metadata}

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
        updated_pane = apply_parent_pane_updates(pane, updates)

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
  def render(%{kind: :parent_mcp_call} = pane), do: render_pane(pane)

  def render(%{working: working, completed: completed, focused: focused, open: open})
      when is_list(working) and is_list(completed) and is_list(open) do
    %{
      id: :parent_mcp_calls,
      title: "Parent MCP",
      empty?: working == [] and completed == [],
      focused: focused,
      open: open,
      working: Enum.map(working, &render_pane/1),
      completed: Enum.map(completed, &render_pane/1)
    }
  end

  @doc """
  Formats a rendered or raw parent MCP pane as a compact terminal line.
  """
  @spec render_line(parent_pane() | rendered_parent_pane()) :: String.t()
  def render_line(%{line: line}) when is_binary(line), do: line

  def render_line(%{kind: :parent_mcp_call} = pane),
    do: pane |> render_pane() |> Map.fetch!(:line)

  @doc """
  Builds a parent MCP pane projection from a normalized lifecycle event.
  """
  @spec from_lifecycle_event(map()) :: {:ok, parent_pane()} | :ignore
  def from_lifecycle_event(event) when is_map(event) do
    with true <- parent_lifecycle_event?(event),
         {:ok, parent_call_id} <- required_string(event, :parent_call_id),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, transport} <- required_atom(event, :transport) do
      event_seq = integer_value(event, :event_seq, 0)
      occurred_at_ms = integer_value(event, :occurred_at_ms, System.system_time(:millisecond))
      type = Map.get(event, :type)

      {:ok,
       %{
         id: pane_id(parent_call_id),
         kind: :parent_mcp_call,
         status: status_for(type),
         parent_call_id: parent_call_id,
         runtime_source: runtime_source,
         transport: transport,
         external_ids: external_ids_map(event),
         request_id: string_value(event, :request_id, nil),
         method: string_value(event, :method, nil),
         params: Map.get(event, :params),
         result: Map.get(event, :result),
         error: Map.get(event, :error),
         notification: Map.get(event, :notification),
         stream_cursor: %{
           transport: transport,
           parent_call_id: parent_call_id,
           event_seq: event_seq
         },
         pane_state: %{
           open?: true,
           focused?: false,
           renderer: :default_parent_mcp,
           lifecycle_type: type,
           last_event_seq: event_seq,
           event_count: 1,
           notification_count: notification_count(event)
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
  Builds a local parent pane cleanup instruction from supervised stream cleanup.

  External runtime status remains trusted; cleanup only removes dashboard-local
  live projection state after the OTP stream boundary has released resources.
  """
  @spec from_cleanup_event(map()) :: {:ok, map()} | :ignore
  def from_cleanup_event(%{cleanup_reason: cleanup_reason, stream_kind: stream_kind} = event)
      when cleanup_reason in [:idle_timeout, :operation_timeout] and
             stream_kind in [:child, :session, :transport] do
    with {:ok, parent_call_id} <- cleanup_parent_call_id(event) do
      {:ok, %{parent_call_id: parent_call_id}}
    end
  end

  def from_cleanup_event(%{lifecycle_type: :stream_terminated} = event) do
    from_cleanup_event(Map.delete(event, :lifecycle_type))
  end

  def from_cleanup_event(_event), do: :ignore

  defp render_pane(%{kind: :parent_mcp_call} = pane) do
    lifecycle = get_in(pane, [:pane_state, :lifecycle_type])
    event_count = get_in(pane, [:pane_state, :event_count]) || 0
    notification_count = get_in(pane, [:pane_state, :notification_count]) || 0
    child_id = child_id(pane.external_ids)

    rendered = %{
      id: pane.id,
      kind: :parent_mcp_call,
      title: "Parent MCP",
      status: Atom.to_string(pane.status),
      lifecycle: stringify(lifecycle, "unknown"),
      parent_call_id: pane.parent_call_id,
      runtime_source: pane.runtime_source,
      transport: Atom.to_string(pane.transport),
      request_id: Map.get(pane, :request_id),
      method: Map.get(pane, :method),
      child_id: child_id,
      external_ids: pane.external_ids,
      stream_cursor: pane.stream_cursor,
      event_count: event_count,
      notification_count: notification_count,
      updated_at_ms: pane.updated_at_ms
    }

    Map.put(rendered, :line, line_for(rendered))
  end

  defp line_for(rendered) do
    [
      "[#{rendered.status}]",
      "parent=#{rendered.parent_call_id}",
      "lifecycle=#{rendered.lifecycle}",
      "runtime=#{rendered.runtime_source}",
      "transport=#{rendered.transport}",
      maybe_segment("request", rendered.request_id),
      maybe_segment("method", rendered.method),
      maybe_segment("child", rendered.child_id),
      "seq=#{rendered.stream_cursor.event_seq}",
      "events=#{rendered.event_count}",
      "notifications=#{rendered.notification_count}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp merge_existing(panes, pane) do
    case Enum.find(panes, &(&1.id == pane.id)) do
      nil -> pane
      existing -> merge_pane(existing, pane)
    end
  end

  defp upsert_pane([], pane), do: [pane]

  defp upsert_pane([%{id: id} = existing | rest], %{id: id} = pane) do
    [merge_pane(existing, pane) | rest]
  end

  defp upsert_pane([existing | rest], pane), do: [existing | upsert_pane(rest, pane)]

  defp merge_pane(existing, pane) do
    event_count = get_in(existing, [:pane_state, :event_count]) || 0
    notification_count = get_in(existing, [:pane_state, :notification_count]) || 0

    existing
    |> Map.merge(pane, fn _key, old, new -> new || old end)
    |> Map.put(:created_at_ms, existing.created_at_ms)
    |> Map.put(:external_ids, Map.merge(existing.external_ids, pane.external_ids))
    |> Map.put(
      :pane_state,
      existing.pane_state
      |> Map.merge(pane.pane_state)
      |> Map.put(:event_count, event_count + 1)
      |> Map.put(:notification_count, notification_count + pane.pane_state.notification_count)
    )
  end

  defp reject_pane(panes, pane_id), do: Enum.reject(panes, &(&1.id == pane_id))

  defp replace_pane(panes, pane_id, updated_pane) do
    Enum.map(panes, fn
      %{id: ^pane_id} -> updated_pane
      pane -> pane
    end)
  end

  defp apply_parent_pane_updates(pane, updates) do
    pane
    |> maybe_update_scalar(:status, updates, &normalize_status/1)
    |> maybe_update_scalar(:runtime_source, updates, &normalize_string/1)
    |> maybe_update_scalar(:transport, updates, &normalize_transport/1)
    |> maybe_update_scalar(:request_id, updates, &normalize_optional_string/1)
    |> maybe_update_scalar(:method, updates, &normalize_optional_string/1)
    |> maybe_update_value(:params, updates)
    |> maybe_update_value(:result, updates)
    |> maybe_update_value(:error, updates)
    |> maybe_update_value(:notification, updates)
    |> maybe_merge_map(:external_ids, updates)
    |> maybe_merge_map(:stream_cursor, updates)
    |> maybe_merge_map(:pane_state, updates)
    |> maybe_update_scalar(:updated_at_ms, updates, &normalize_integer/1)
    |> Map.put(:id, pane.id)
    |> Map.put(:kind, :parent_mcp_call)
    |> Map.put(:parent_call_id, pane.parent_call_id)
    |> Map.put(:created_at_ms, pane.created_at_ms)
    |> ensure_stream_cursor_identity()
  end

  defp ensure_stream_cursor_identity(pane) do
    stream_cursor =
      pane.stream_cursor
      |> Map.put(:transport, pane.transport)
      |> Map.put(:parent_call_id, pane.parent_call_id)

    Map.put(pane, :stream_cursor, stream_cursor)
  end

  defp maybe_update_scalar(pane, key, updates, normalizer) do
    case metadata_value(updates, key) do
      nil ->
        pane

      value ->
        case normalizer.(value) do
          nil -> pane
          normalized -> Map.put(pane, key, normalized)
        end
    end
  end

  defp maybe_update_value(pane, key, updates) do
    if Map.has_key?(updates, key) or Map.has_key?(updates, Atom.to_string(key)) do
      Map.put(pane, key, metadata_value(updates, key))
    else
      pane
    end
  end

  defp maybe_merge_map(pane, key, updates) do
    case metadata_value(updates, key) do
      value when is_map(value) -> Map.put(pane, key, Map.merge(Map.get(pane, key, %{}), value))
      _value -> pane
    end
  end

  defp apply_cleanup_event(state, %{parent_call_id: parent_call_id}) do
    pane_id = pane_id(parent_call_id)

    remove_panes(state, fn pane -> pane.parent_call_id == parent_call_id or pane.id == pane_id end)
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
    end
  end

  defp append_once(values, value) do
    if value in values do
      values
    else
      values ++ [value]
    end
  end

  defp parent_lifecycle_event?(event) do
    case Map.get(event, :type) do
      :parent_call_started -> true
      :parent_call_event -> true
      :parent_call_result -> true
      :parent_call_failed -> true
      :parent_call_write_failed -> true
      :parent_call_unmatched_result -> true
      :transport_decode_failed -> true
      :transport_exited -> true
      _ -> false
    end
  end

  defp terminal?(event), do: MapSet.member?(@terminal_types, Map.get(event, :type))

  defp status_for(:parent_call_started), do: :starting
  defp status_for(:parent_call_event), do: :streaming
  defp status_for(:parent_call_result), do: :completed
  defp status_for(:parent_call_unmatched_result), do: :completed
  defp status_for(_failed_or_exit), do: :failed

  defp pane_id(parent_call_id), do: "parent-mcp:" <> parent_call_id

  defp notification_count(%{type: :parent_call_event}), do: 1
  defp notification_count(_event), do: 0

  defp child_id(external_ids) do
    external_ids
    |> case do
      ids when is_map(ids) ->
        Map.get(ids, :child_id) ||
          Map.get(ids, "child_id") ||
          Map.get(ids, :childID) ||
          Map.get(ids, "childID")

      _ ->
        nil
    end
    |> case do
      value when is_binary(value) and value != "" -> value
      value when is_integer(value) -> Integer.to_string(value)
      _ -> nil
    end
  end

  defp maybe_segment(_key, nil), do: nil
  defp maybe_segment(_key, ""), do: nil
  defp maybe_segment(key, value), do: key <> "=" <> to_string(value)

  defp external_ids_map(event) do
    case Map.get(event, :external_ids) do
      external_ids when is_map(external_ids) -> external_ids
      _ -> %{}
    end
  end

  defp required_string(event, key) do
    case Map.get(event, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp required_atom(event, key) do
    case Map.get(event, key) do
      value when is_atom(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp string_value(map, key, default) do
    case Map.get(map, key) do
      nil -> default
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp stringify(nil, default), do: default
  defp stringify(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value, _default), do: to_string(value)

  defp integer_value(map, key, default) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> default
        end

      _ ->
        default
    end
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_string(metadata, key) do
    case metadata_value(metadata, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_integer(value) -> {:ok, Integer.to_string(value)}
      value when is_atom(value) and not is_nil(value) -> {:ok, Atom.to_string(value)}
      _value -> :error
    end
  end

  defp metadata_string_or_nil(metadata, key) do
    case metadata_string(metadata, key) do
      {:ok, value} -> value
      :error -> nil
    end
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
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} -> integer
          _ -> nil
        end

      _value ->
        nil
    end
  end

  defp metadata_map(metadata, key, default) do
    case metadata_value(metadata, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp normalize_status(status) when status in [:starting, :streaming, :completed, :failed],
    do: status

  defp normalize_status("starting"), do: :starting
  defp normalize_status("streaming"), do: :streaming
  defp normalize_status("completed"), do: :completed
  defp normalize_status("failed"), do: :failed
  defp normalize_status(_status), do: nil

  defp normalize_transport(transport) when transport in [:stdio, :streamable_http, :sse],
    do: transport

  defp normalize_transport("stdio"), do: :stdio
  defp normalize_transport("streamable_http"), do: :streamable_http
  defp normalize_transport("sse"), do: :sse
  defp normalize_transport(_transport), do: nil

  defp normalize_string(value) when is_binary(value) and value != "", do: value
  defp normalize_string(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_string(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalize_string(_value), do: nil

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: normalize_string(value)

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp cleanup_parent_call_id(event) do
    case cleanup_identifier(event, [
           :parent_call_id,
           :parentCallID,
           "parent_call_id",
           "parentCallID"
         ]) do
      nil -> :error
      parent_call_id -> {:ok, parent_call_id}
    end
  end

  defp cleanup_identifier(event, keys) when is_map(event) do
    keys
    |> Enum.find_value(fn key -> normalize_runtime_id(Map.get(event, key)) end)
  end

  defp cleanup_identifier(_event, _keys), do: nil

  defp normalize_runtime_id(value) when is_binary(value) and value != "", do: value
  defp normalize_runtime_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_runtime_id(_value), do: nil
end
