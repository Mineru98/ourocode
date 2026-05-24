defmodule Ourocode.Dashboard.ChildSessionPaneRendererTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneRenderer

  test "renders child pane line and deterministic rendered sequence ids" do
    pane = pane(stream_entries: [%{event_seq: 4, runtime_seq: 7, token: "first"}])

    rendered = ChildSessionPaneRenderer.render(pane)

    assert rendered.line ==
             "[working] child=child-1 pane=child-session:child-1 parent=parent-1 runtime=runtime transport=stdio seq=4 events=1"

    assert rendered.rendered_sequences == [
             %{
               id: "rendered-seq:child-session:child-1:event=4:runtime=7:index=1",
               pane_id: "child-session:child-1",
               child_id: "child-1",
               child_event_id: nil,
               event_seq: 4,
               runtime_seq: 7,
               rendered_index: 1
             }
           ]

    assert [%{rendered_sequence_id: sequence_id, child_event_id: nil}] =
             rendered.pane_state.stream_entries

    assert sequence_id == hd(rendered.rendered_sequences).id
  end

  test "uses explicit child event ids and includes replay gaps" do
    pane =
      pane(
        pane_state: %{
          title: "Focused child",
          last_event_seq: 9,
          replay_gap_error: %{missing_event_seq_range: %{from: 5, to: 8}},
          stream_entries: [%{"child_event_id" => "child-event-1", "event_seq" => 9}]
        }
      )

    rendered = ChildSessionPaneRenderer.render(pane)

    assert rendered.title == "Focused child"
    assert rendered.rendered_sequences |> hd() |> Map.fetch!(:id) == "rendered-seq:child-event-1"
    assert rendered.line =~ "gap=5..8"
  end

  test "render_line accepts already rendered panes" do
    assert ChildSessionPaneRenderer.render_line(%{line: "ready"}) == "ready"
  end

  defp pane(overrides) do
    pane_state =
      Keyword.get(overrides, :pane_state, %{
        last_event_seq: 4,
        stream_entries: Keyword.get(overrides, :stream_entries, [])
      })

    %{
      id: "child-session:child-1",
      kind: :child_session,
      status: :working,
      child_id: "child-1",
      parent_call_id: "parent-1",
      runtime_source: "runtime",
      transport: :stdio,
      external_ids: %{"childID" => "child-1"},
      stream_cursor: %{event_seq: 4},
      pane_state: pane_state,
      created_at_ms: 1,
      updated_at_ms: 2
    }
  end
end
