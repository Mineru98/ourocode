defmodule Ourocode.Journal.Sequence do
  @moduledoc """
  Assigns append-time journal event sequence numbers.
  """

  @spec event_seq_for_append(map(), [map()]) ::
          {:ok, integer()}
          | {:error, {:event_seq_gap, integer(), integer()} | {:invalid_event_seq, term()}}
  def event_seq_for_append(%{"event_seq" => event_seq}, entries) when is_integer(event_seq) do
    case entries do
      [] ->
        {:ok, event_seq}

      _entries ->
        expected_event_seq = next_event_seq_from_entries(entries)

        if event_seq == expected_event_seq do
          {:ok, event_seq}
        else
          {:error, {:event_seq_gap, expected_event_seq, event_seq}}
        end
    end
  end

  def event_seq_for_append(%{"event_seq" => event_seq}, _entries) do
    {:error, {:invalid_event_seq, event_seq}}
  end

  def event_seq_for_append(_record, entries), do: {:ok, next_event_seq_from_entries(entries)}

  @spec next_event_seq_from_entries([map()]) :: integer()
  def next_event_seq_from_entries(entries) do
    entries
    |> Enum.map(&(Map.get(&1, :event_seq) || Map.get(&1, "event_seq")))
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> 1
      event_seqs -> Enum.max(event_seqs) + 1
    end
  end
end
