defmodule Ourocode.Journal.ReplayLoader do
  @moduledoc """
  Loads normalized journal events for session replay after interruption.

  The loader is intentionally a thin recovery boundary around `Ourocode.Journal`.
  It uses the same decoder as runtime replay, then emits explicit evidence that
  every durable JSONL record became exactly one recovered normalized event and
  that journal `event_seq` values are contiguous and unique.
  """

  alias Ourocode.Journal

  @type load_report :: %{
          type: :journal_replay_loader,
          status: :ok,
          persisted_record_count: non_neg_integer(),
          recovered_event_count: non_neg_integer(),
          first_event_seq: integer() | nil,
          last_event_seq: integer() | nil,
          expected_event_seqs: [integer()],
          recovered_event_seqs: [integer()],
          missing_event_seqs: [integer()],
          duplicate_event_seqs: [integer()],
          skipped_event_count: non_neg_integer(),
          duplicated_event_count: non_neg_integer()
        }

  @type load_result :: %{
          events: [Journal.entry()],
          report: load_report()
        }

  @doc """
  Recovers all journaled normalized events and returns replay evidence.

  This is the loader used by restart/replay paths after an interrupted session.
  It fails closed when any durable record is skipped, duplicated, or carries a
  non-contiguous `event_seq`, because those cases would make terminal replay
  diverge from the persisted event stream.
  """
  @spec load(Path.t()) :: {:ok, load_result()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, events} <- Journal.replay_normalized_events(path),
         {:ok, persisted_record_count} <- persisted_record_count(path),
         {:ok, report} <- verify_recovery(events, persisted_record_count) do
      {:ok, %{events: events, report: report}}
    end
  end

  @doc """
  Convenience function for callers that only need the recovered event stream.
  """
  @spec load_events(Path.t()) :: {:ok, [Journal.entry()]} | {:error, term()}
  def load_events(path) when is_binary(path) do
    with {:ok, %{events: events}} <- load(path), do: {:ok, events}
  end

  @doc """
  Verifies an already-decoded replay stream against the durable record count.
  """
  @spec verify_recovery([Journal.entry()], non_neg_integer()) ::
          {:ok, load_report()} | {:error, map()}
  def verify_recovery(events, persisted_record_count)
      when is_list(events) and is_integer(persisted_record_count) and persisted_record_count >= 0 do
    recovered_event_count = length(events)
    recovered_event_seqs = Enum.map(events, &Map.get(&1, :event_seq))
    expected_event_seqs = expected_event_seqs(recovered_event_seqs)
    duplicate_event_seqs = duplicate_event_seqs(recovered_event_seqs)
    missing_event_seqs = expected_event_seqs -- recovered_event_seqs

    report = %{
      type: :journal_replay_loader,
      status: :ok,
      persisted_record_count: persisted_record_count,
      recovered_event_count: recovered_event_count,
      first_event_seq: List.first(recovered_event_seqs),
      last_event_seq: List.last(recovered_event_seqs),
      expected_event_seqs: expected_event_seqs,
      recovered_event_seqs: recovered_event_seqs,
      missing_event_seqs: missing_event_seqs,
      duplicate_event_seqs: duplicate_event_seqs,
      skipped_event_count: length(missing_event_seqs),
      duplicated_event_count: length(duplicate_event_seqs)
    }

    cond do
      Enum.any?(recovered_event_seqs, &(not is_integer(&1))) ->
        {:error,
         report
         |> Map.put(:status, :failed)
         |> Map.put(:reason, :invalid_recovered_event_seq)}

      recovered_event_count != persisted_record_count ->
        {:error,
         report
         |> Map.put(:status, :failed)
         |> Map.put(:reason, :persisted_record_recovery_count_mismatch)}

      recovered_event_seqs != expected_event_seqs ->
        {:error,
         report
         |> Map.put(:status, :failed)
         |> Map.put(:reason, :journal_replay_event_seq_not_contiguous)}

      true ->
        {:ok, report}
    end
  end

  defp persisted_record_count(path) do
    with {:ok, contents} <- File.read(path) do
      count =
        contents
        |> String.split(["\r\n", "\n", "\r"], trim: true)
        |> length()

      {:ok, count}
    end
  end

  defp expected_event_seqs([]), do: []

  defp expected_event_seqs([first | _] = event_seqs) when is_integer(first) do
    Enum.to_list(first..(first + length(event_seqs) - 1)//1)
  end

  defp expected_event_seqs(_event_seqs), do: []

  defp duplicate_event_seqs(event_seqs) do
    event_seqs
    |> Enum.frequencies()
    |> Enum.filter(fn {_event_seq, count} -> count > 1 end)
    |> Enum.map(fn {event_seq, _count} -> event_seq end)
    |> Enum.sort()
  end
end
