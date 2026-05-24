defmodule Ourocode.Terminal.FooterRuntimeStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.FooterRuntimeState

  test "projects runtime, stream, journal, transport, and replay state" do
    projection =
      FooterRuntimeState.project(
        %{
          stream: %{status: :startup_stream},
          journal: %{status: :startup_journal},
          transports: [:stdio],
          replayable?: false
        },
        %{
          stream: %{status: :context_stream},
          journal: %{status: :context_journal},
          transports: [%{type: :sse, status: :connecting}],
          replayable?: true
        },
        %{
          status: :ready,
          stream: %{status: :flowing},
          journal: %{status: :open},
          transports: [
            %{type: :stdio, status: :connected},
            %{"type" => "streamable_http", "status" => "connected"}
          ]
        }
      )

    assert projection == %{
             runtime_status: :ready,
             stream_status: :flowing,
             journal_status: :open,
             transport_statuses: [
               "stdio:unknown",
               "sse:connecting",
               "stdio:connected",
               "streamable_http:connected"
             ],
             replayable?: true
           }
  end

  test "uses safe defaults for missing runtime state" do
    assert FooterRuntimeState.project(%{}, %{}, %{}) == %{
             runtime_status: :unknown,
             stream_status: :unknown,
             journal_status: :unknown,
             transport_statuses: [],
             replayable?: false
           }

    assert FooterRuntimeState.transport_text([]) == "none"
  end

  test "formats compact transport text" do
    assert FooterRuntimeState.transport_text(["stdio:connected", "sse:connecting"]) ==
             "stdio:connected,sse:connecting"
  end
end
