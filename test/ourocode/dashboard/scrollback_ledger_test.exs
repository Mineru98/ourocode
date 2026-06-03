defmodule Ourocode.Dashboard.ScrollbackLedgerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ScrollbackLedger

  test "projects child stream entries into selectable scrollback blocks" do
    ledger =
      pane([
        %{
          event_seq: 1,
          runtime_seq: 1,
          token: "thinking",
          payload: %{"token" => "thinking"}
        },
        %{
          event_seq: 2,
          runtime_seq: 2,
          payload: %{
            "tool_call_id" => "tool-1",
            "tool_name" => "ouroboros__start_ralph",
            "arguments" => %{"lineage_id" => "lin-1"}
          }
        },
        %{
          event_seq: 3,
          runtime_seq: 3,
          payload: %{
            "tool_call_id" => "tool-1",
            "status" => "completed",
            "result" => "started child session"
          }
        }
      ])
      |> ScrollbackLedger.from_child_pane()

    assert ledger.kind == :scrollback_ledger
    assert ledger.selectable?
    assert ledger.block_count == 3
    assert ledger.selected_block_id == ledger.blocks |> List.last() |> Map.fetch!(:id)

    assert [
             %{kind: :message, collapsed?: false, summary: "thinking"},
             %{kind: :tool_call, title: "Tool ouroboros__start_ralph", collapsed?: true},
             %{kind: :tool_call, status: :completed, summary: "started child session"}
           ] = ledger.blocks
  end

  test "redacts secrets from payloads and detail previews" do
    ledger =
      pane([
        %{
          event_seq: 1,
          runtime_seq: 1,
          payload: %{
            "tool_name" => "remote__fetch",
            "url" => "https://example.com/mcp?tavilyApiKey=tvly-secret-value",
            "Authorization" => "Bearer live-token",
            "nested" => %{"api_key" => "sk-test"}
          }
        }
      ])
      |> ScrollbackLedger.from_child_pane()

    [block] = ledger.blocks

    refute block.detail_preview =~ "tvly-secret-value"
    refute block.detail_preview =~ "Bearer live-token"
    refute block.detail_preview =~ "sk-test"
    assert block.detail_preview =~ "[redacted]"
  end

  defp pane(stream_entries) do
    %{
      id: "child-session:ledger-child",
      kind: :child_session,
      status: :working,
      child_id: "ledger-child",
      parent_call_id: "parent-ledger",
      runtime_source: "ouroboros",
      transport: :stdio,
      external_ids: %{"childID" => "ledger-child"},
      stream_cursor: %{event_seq: 3},
      pane_state: %{stream_entries: stream_entries},
      created_at_ms: 1,
      updated_at_ms: 2
    }
  end
end
