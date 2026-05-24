defmodule Ourocode.MCP.Transport.Stdio.State do
  @moduledoc """
  Initial stdio transport state construction.
  """

  alias Ourocode.MCP.Transport.Stdio
  alias Ourocode.MCP.Transport.Stdio.Cleanup

  @spec build(port() | term(), keyword(), integer()) :: Stdio.t()
  def build(port, opts, now_ms \\ Cleanup.monotonic_ms()) when is_list(opts) do
    cleanup_timeout_ms = Cleanup.timeout_ms(opts)

    %Stdio{
      port: port,
      event_sink: Keyword.get(opts, :event_sink, self()),
      parent_call_id: Keyword.get(opts, :parent_call_id, new_id("parent")),
      runtime_source: Keyword.get(opts, :runtime_source, "synthetic"),
      external_ids: Keyword.get(opts, :external_ids, %{}),
      journal_path: Keyword.get(opts, :journal_path),
      codec: Keyword.get(opts, :codec, Ourocode.Json),
      cleanup_timeout_ms: cleanup_timeout_ms,
      cleanup_timer_ref: Cleanup.schedule_timer(cleanup_timeout_ms, now_ms),
      last_activity_monotonic_ms: now_ms
    }
  end

  defp new_id(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
