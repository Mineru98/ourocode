defmodule Ourocode.MCP.Transport.Stdio.Snapshot do
  @moduledoc """
  Read-only projection of stdio transport state for supervision and tests.
  """

  alias Ourocode.MCP.Transport.Stdio.Cleanup

  @spec build(map()) :: map()
  def build(state) when is_map(state) do
    %{
      transport: :stdio,
      parent_call_id: state.parent_call_id,
      runtime_source: state.runtime_source,
      external_ids: state.external_ids,
      event_seq: state.event_seq,
      request_seq: state.request_seq,
      pending_request_count: map_size(state.pending),
      port: state.port,
      port_open?: Cleanup.port_open?(state.port),
      cleanup_timeout_ms: state.cleanup_timeout_ms,
      last_activity_monotonic_ms: state.last_activity_monotonic_ms
    }
  end
end
