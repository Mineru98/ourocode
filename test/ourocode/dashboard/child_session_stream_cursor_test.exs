defmodule Ourocode.Dashboard.ChildSessionStreamCursorTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionStreamCursor

  test "stream_cursor merges explicit event cursor with transport sequence and child id" do
    event = %{stream_cursor: %{cursor: "upstream-1", offset: 9}}

    assert ChildSessionStreamCursor.stream_cursor(event, :sse, 12, "child-1") == %{
             cursor: "upstream-1",
             offset: 9,
             transport: :sse,
             event_seq: 12,
             child_id: "child-1"
           }
  end

  test "stream_cursor finds nested raw event data params cursor variants" do
    event = %{
      raw_event: %{
        "data" => %{
          "params" => %{
            "streamCursor" => "cursor-7"
          }
        }
      }
    }

    assert ChildSessionStreamCursor.stream_cursor(event, :streamable_http, 7, "child-7") == %{
             cursor: "cursor-7",
             transport: :streamable_http,
             event_seq: 7,
             child_id: "child-7"
           }
  end

  test "stream_cursor normalizes integer cursors and falls back to local cursor fields" do
    event = %{result: %{cursor: 42}}

    assert ChildSessionStreamCursor.stream_cursor(event, :stdio, 3, "child-3") == %{
             cursor: 42,
             transport: :stdio,
             event_seq: 3,
             child_id: "child-3"
           }
  end

  test "stream_cursor always returns local cursor data when no upstream cursor exists" do
    assert ChildSessionStreamCursor.stream_cursor(%{}, :stdio, 1, "child-1") == %{
             transport: :stdio,
             event_seq: 1,
             child_id: "child-1"
           }
  end
end
