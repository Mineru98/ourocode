defmodule Ourocode.Dashboard.ChildSessionPaneRenderer do
  @moduledoc false

  alias Ourocode.Dashboard.ScrollbackLedger

  @spec render(map()) :: map()
  def render(%{kind: :child_session} = pane) do
    stream_entries = stream_entries(pane)
    rendered_sequences = rendered_sequences(pane, stream_entries)
    rendered_pane_state = put_rendered_sequence_ids(pane.pane_state, rendered_sequences)
    ledger_pane = %{pane | pane_state: rendered_pane_state}
    scrollback_ledger = ScrollbackLedger.from_child_pane(ledger_pane)

    rendered = %{
      id: pane.id,
      kind: :child_session,
      title: child_title(pane),
      status: Atom.to_string(pane.status),
      child_id: pane.child_id,
      parent_call_id: pane.parent_call_id,
      runtime_source: pane.runtime_source,
      transport: Atom.to_string(pane.transport),
      external_ids: pane.external_ids,
      stream_cursor: pane.stream_cursor,
      pane_state: rendered_pane_state,
      rendered_sequences: rendered_sequences,
      scrollback_ledger: scrollback_ledger,
      replay_gap_error: replay_gap_error(pane),
      stream_event_count: length(stream_entries),
      ledger_block_count: scrollback_ledger.block_count,
      last_event_seq: get_in(rendered_pane_state, [:last_event_seq]),
      updated_at_ms: pane.updated_at_ms
    }

    Map.put(rendered, :line, line_for(rendered))
  end

  @spec render_line(map()) :: String.t()
  def render_line(%{line: line}) when is_binary(line), do: line
  def render_line(%{kind: :child_session} = pane), do: pane |> render() |> Map.fetch!(:line)

  @spec stream_entries(map()) :: [term()]
  def stream_entries(%{pane_state: pane_state}) when is_map(pane_state) do
    case Map.get(pane_state, :stream_entries, []) do
      entries when is_list(entries) -> entries
      _entries -> []
    end
  end

  def stream_entries(_pane), do: []

  defp rendered_sequences(%{id: pane_id, child_id: child_id}, stream_entries) do
    stream_entries
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, rendered_index} ->
      event_seq = stream_entry_value(entry, :event_seq)
      runtime_seq = stream_entry_value(entry, :runtime_seq)

      %{
        id: rendered_sequence_id(pane_id, entry, event_seq, runtime_seq, rendered_index),
        pane_id: pane_id,
        child_id: child_id,
        child_event_id: stream_entry_value(entry, :child_event_id),
        event_seq: event_seq,
        runtime_seq: runtime_seq,
        rendered_index: rendered_index
      }
    end)
  end

  defp put_rendered_sequence_ids(pane_state, []), do: pane_state

  defp put_rendered_sequence_ids(pane_state, rendered_sequences) when is_map(pane_state) do
    entries = Map.get(pane_state, :stream_entries, [])

    rendered_entries =
      entries
      |> Enum.zip(rendered_sequences)
      |> Enum.map(fn {entry, sequence} ->
        if is_map(entry) do
          Map.put(entry, :rendered_sequence_id, sequence.id)
          |> Map.put(:child_event_id, sequence.child_event_id)
        else
          entry
        end
      end)

    Map.put(pane_state, :stream_entries, rendered_entries)
  end

  defp put_rendered_sequence_ids(pane_state, _rendered_sequences), do: pane_state

  defp rendered_sequence_id(pane_id, entry, event_seq, runtime_seq, rendered_index) do
    case stream_entry_value(entry, :child_event_id) do
      child_event_id when is_binary(child_event_id) and child_event_id != "" ->
        "rendered-seq:" <> child_event_id

      _child_event_id ->
        [
          "rendered-seq",
          pane_id,
          "event=#{sequence_component(event_seq)}",
          "runtime=#{sequence_component(runtime_seq)}",
          "index=#{rendered_index}"
        ]
        |> Enum.join(":")
    end
  end

  defp sequence_component(nil), do: "none"
  defp sequence_component(value), do: to_string(value)

  defp stream_entry_value(entry, key) when is_map(entry) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp stream_entry_value(_entry, _key), do: nil

  defp line_for(rendered) do
    [
      "[#{rendered.status}]",
      "child=#{rendered.child_id}",
      "pane=#{rendered.id}",
      "parent=#{rendered.parent_call_id}",
      "runtime=#{rendered.runtime_source}",
      "transport=#{rendered.transport}",
      maybe_segment("seq", rendered.last_event_seq),
      replay_gap_segment(rendered.replay_gap_error),
      "events=#{rendered.stream_event_count}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp child_title(pane) do
    case get_in(pane, [:pane_state, :title]) do
      title when is_binary(title) and title != "" -> title
      _title -> "Child Session"
    end
  end

  defp replay_gap_error(%{pane_state: pane_state}) when is_map(pane_state) do
    Map.get(pane_state, :replay_gap_error) || Map.get(pane_state, "replay_gap_error")
  end

  defp replay_gap_error(_pane), do: nil

  defp replay_gap_segment(%{missing_event_seq_range: %{from: from, to: to}}),
    do: "gap=#{from}..#{to}"

  defp replay_gap_segment(%{"missing_event_seq_range" => %{"from" => from, "to" => to}}),
    do: "gap=#{from}..#{to}"

  defp replay_gap_segment(_gap), do: nil

  defp maybe_segment(_key, nil), do: nil
  defp maybe_segment(_key, ""), do: nil
  defp maybe_segment(key, value), do: key <> "=" <> to_string(value)
end
