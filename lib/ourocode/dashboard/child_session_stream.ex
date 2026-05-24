defmodule Ourocode.Dashboard.ChildSessionStream do
  @moduledoc """
  Normalizes child-session stream cursors and renderable stream entries.
  """

  alias Ourocode.Dashboard.ChildSessionStreamCursor
  alias Ourocode.Dashboard.ChildSessionStreamEntry

  @spec stream_cursor(map(), atom(), integer(), String.t()) :: map()
  def stream_cursor(event, transport, event_seq, child_id) do
    ChildSessionStreamCursor.stream_cursor(event, transport, event_seq, child_id)
  end

  @spec stream_entries_for_event(map(), integer(), integer()) :: [map()]
  def stream_entries_for_event(event, event_seq, occurred_at_ms) do
    ChildSessionStreamEntry.entries_for_event(event, event_seq, occurred_at_ms)
  end
end
