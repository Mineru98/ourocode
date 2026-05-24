defmodule Ourocode.MCP.Transport.SSE.State do
  @moduledoc """
  Initial SSE transport state construction.

  This module keeps option defaulting and identifier derivation out of the
  GenServer lifecycle so connection setup remains easy to inspect.
  """

  alias Ourocode.MCP.Transport.Http
  alias Ourocode.MCP.Transport.SSE
  alias Ourocode.MCP.Transport.SSE.RawEvent
  alias Ourocode.MCP.Transport.SSE.SessionIdentifier

  @spec build(term(), URI.t(), keyword()) :: SSE.t()
  def build(socket, %URI{} = uri, opts) when is_list(opts) do
    external_ids = Keyword.get(opts, :external_ids, %{})
    journal_path = Keyword.get(opts, :journal_path)

    %SSE{
      socket: socket,
      event_sink: Keyword.get(opts, :event_sink, self()),
      parent_call_id: Keyword.get(opts, :parent_call_id, new_id("parent")),
      runtime_source: Keyword.get(opts, :runtime_source, "synthetic"),
      external_ids: external_ids,
      dispatch_uri:
        Http.parse_optional_http_url!(Keyword.get(opts, :dispatch_url), "SSE dispatch_url"),
      endpoint_url: URI.to_string(uri),
      connection_identifier: Keyword.get(opts, :connection_identifier, new_id("sse-connection")),
      session_identifier:
        Keyword.get(
          opts,
          :session_identifier,
          SessionIdentifier.from_uri_and_external_ids(uri, external_ids)
        ),
      request_headers: Keyword.get(opts, :headers, []),
      journal_path: journal_path,
      raw_payload_store_dir:
        Keyword.get(opts, :raw_payload_store_dir) || RawEvent.default_store_dir(journal_path),
      event_seq: Keyword.get(opts, :event_seq, 0)
    }
  end

  defp new_id(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
