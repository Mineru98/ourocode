defmodule Ourocode.Terminal.EventLoopJournalTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.Terminal.EventLoopJournal

  test "append is a no-op without a journal path" do
    assert EventLoopJournal.append(nil, %{type: :prompt_input_submitted}) == :ok
  end

  test "persist returns the original event without a journal path" do
    event = %{type: :slash_command_submitted, command: "/help"}

    assert EventLoopJournal.persist(nil, event) == {:ok, event}
  end

  test "persist journals the event and returns its assigned event sequence" do
    path = journal_path("event-loop-journal-persist")
    event = %{type: :slash_command_submitted, command: "/help"}

    assert {:ok, %{event_seq: 1} = persisted} = EventLoopJournal.persist(path, event)
    assert persisted.command == "/help"

    assert {:ok, [%{event_seq: 1, type: :slash_command_submitted, command: "/help"}]} =
             Journal.read_ordered(path)
  end

  defp journal_path(name) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")

    File.rm(path)
    path
  end
end
