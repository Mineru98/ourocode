defmodule Ourocode.Dashboard.SessionListPane do
  @moduledoc """
  Compact session list pane.

  This renderer owns only dashboard projection concerns: it turns journal or
  runtime session state into stable compact rows for active and finished work.
  External runtime IDs remain trusted inputs; ourocode stores the local pane
  projection.
  """

  @working_statuses MapSet.new([:active, :running, "active", "running"])
  @completed_statuses MapSet.new([
                        :completed,
                        :complete,
                        :finished,
                        :succeeded,
                        :failed,
                        :cancelled,
                        :canceled,
                        "completed",
                        "complete",
                        "finished",
                        "succeeded",
                        "failed",
                        "cancelled",
                        "canceled"
                      ])

  @required_row_keys [
    :session_id,
    :child_id,
    :runtime_source,
    :transport,
    :status,
    :task_label,
    :parent_call_id,
    :event_seq
  ]

  @type session :: map()
  @type row :: %{
          required(:session_id) => String.t(),
          required(:child_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:transport) => String.t(),
          required(:status) => String.t(),
          required(:task_label) => String.t(),
          required(:parent_call_id) => String.t(),
          required(:event_seq) => non_neg_integer(),
          optional(:stream_cursor) => map(),
          optional(:updated_at_ms) => integer()
        }

  @doc """
  Renders the working session list pane from raw session state.
  """
  @spec render([session()]) :: map()
  def render(sessions) when is_list(sessions) do
    render_working(sessions)
  end

  @doc """
  Renders the requested session list pane from raw session state.
  """
  @spec render([session()], :working | :completed) :: map()
  def render(sessions, :working) when is_list(sessions), do: render_working(sessions)
  def render(sessions, :completed) when is_list(sessions), do: render_completed(sessions)

  @doc """
  Renders the working session list pane from raw session state.
  """
  @spec render_working([session()]) :: map()
  def render_working(sessions) when is_list(sessions) do
    rows =
      sessions
      |> Enum.filter(&working?/1)
      |> Enum.map(&compact_row/1)

    %{
      id: :working_sessions,
      title: "Working",
      empty?: rows == [],
      rows: rows
    }
  end

  @doc """
  Renders the completed session list pane from raw session state.
  """
  @spec render_completed([session()]) :: map()
  def render_completed(sessions) when is_list(sessions) do
    rows =
      sessions
      |> Enum.filter(&completed?/1)
      |> Enum.map(&compact_row/1)

    %{
      id: :completed_sessions,
      title: "Completed",
      empty?: rows == [],
      rows: rows
    }
  end

  @doc """
  Returns a compact row with stable metadata required by the dashboard.
  """
  @spec compact_row(session()) :: row()
  def compact_row(session) when is_map(session) do
    external_ids = map_value(session, :external_ids, %{})

    row = %{
      session_id: first_present(session, external_ids, [:session_id, :native_session_id, :thread_id]),
      child_id:
        first_present(session, external_ids, [
          :child_id,
          :childID,
          :execution_id,
          :job_id,
          :lineage_id
        ]),
      runtime_source: string_value(session, :runtime_source, "unknown"),
      transport: string_value(session, :transport, "unknown"),
      status: string_value(session, :status, "unknown"),
      task_label: task_label(session),
      parent_call_id: string_value(session, :parent_call_id, "unmapped"),
      event_seq: integer_value(session, :event_seq, 0)
    }

    row
    |> maybe_put(:stream_cursor, map_value(session, :stream_cursor, nil))
    |> maybe_put(:updated_at_ms, integer_value(session, :updated_at_ms, nil))
    |> Map.take(@required_row_keys ++ [:stream_cursor, :updated_at_ms])
  end

  @doc """
  Formats a compact row for terminal rendering.
  """
  @spec render_row(row()) :: String.t()
  def render_row(row) when is_map(row) do
    [
      "[#{row.status}]",
      row.task_label,
      "session=#{row.session_id}",
      "child=#{row.child_id}",
      "runtime=#{row.runtime_source}",
      "transport=#{row.transport}",
      "parent=#{row.parent_call_id}",
      "seq=#{row.event_seq}"
    ]
    |> Enum.join(" ")
  end

  defp working?(session) do
    MapSet.member?(@working_statuses, value(session, :status))
  end

  defp completed?(session) do
    MapSet.member?(@completed_statuses, value(session, :status))
  end

  defp task_label(session) do
    session
    |> string_value(:task_input, "Untitled task")
    |> String.trim()
    |> compact_text(48)
  end

  defp compact_text("", _limit), do: "Untitled task"

  defp compact_text(text, limit) when byte_size(text) <= limit, do: text

  defp compact_text(text, limit) do
    text
    |> binary_part(0, limit - 1)
    |> Kernel.<>("...")
  end

  defp first_present(session, external_ids, keys) do
    keys
    |> Enum.map(fn key -> value(session, key) || value(external_ids, key) end)
    |> Enum.find(&present?/1)
    |> stringify("unknown")
  end

  defp string_value(map, key, default) do
    map
    |> value(key)
    |> stringify(default)
  end

  defp integer_value(map, key, default) do
    case value(map, key) do
      value when is_integer(value) -> value
      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> default
        end

      _ -> default
    end
  end

  defp map_value(map, key, default) do
    case value(map, key) do
      value when is_map(value) -> value
      _ -> default
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp stringify(nil, default), do: default
  defp stringify(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value, _default), do: to_string(value)

  defp present?(value), do: value not in [nil, ""]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
