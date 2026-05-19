defmodule Ourocode.MCP.Transport.StreamableHTTP.Parser do
  @moduledoc """
  Incremental parser for streamable HTTP MCP response bodies.

  Streamable HTTP carries MCP server events as `text/event-stream` chunks.
  This parser preserves incomplete trailing bytes between socket reads and
  emits complete SSE events in wire order.
  """

  alias Ourocode.Json
  alias Ourocode.MCP.Transport.SSE

  @type parsed_event :: map()

  @doc """
  Parses complete `text/event-stream` frames from a stream buffer.

  The returned `rest` is the exact incomplete suffix that must be prepended to
  the next HTTP body chunk. No event is emitted until its blank-line frame
  delimiter has arrived.
  """
  @spec parse_complete_events(String.t(), module()) ::
          {:ok, [parsed_event()], String.t()} | {:error, term()}
  def parse_complete_events(buffer, codec \\ Json) when is_binary(buffer) do
    SSE.Parser.parse_complete_frames(buffer, codec)
  end
end
