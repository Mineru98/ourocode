defmodule Ourocode.Journal.WriterTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.Reader
  alias Ourocode.Journal.Writer

  test "append_returning_event writes a decoded record with the assigned event sequence" do
    path = journal_path("writer-returning-event")

    assert {:ok, event} =
             Writer.append_returning_event(path, %{
               type: :parent_call_event,
               parent_call_id: "parent-writer-returning",
               runtime_source: "synthetic",
               transport: :stdio,
               occurred_at_ms: 1,
               payload: %{token: "hello"}
             })

    assert event.event_seq == 1
    assert event.payload == %{"token" => "hello"}

    assert {:ok, [persisted]} = Reader.read_ordered(path)
    assert persisted == event
  end

  test "append rejects explicit event sequence gaps without writing the gap record" do
    path = journal_path("writer-gap")

    assert :ok =
             Writer.append(path, %{
               event_seq: 1,
               type: :parent_call_event,
               parent_call_id: "parent-writer-gap",
               runtime_source: "synthetic",
               transport: :stdio,
               occurred_at_ms: 1,
               payload: %{token: "first"}
             })

    assert {:error, {:event_seq_gap, 2, 3}} =
             Writer.append(path, %{
               event_seq: 3,
               type: :parent_call_event,
               parent_call_id: "parent-writer-gap",
               runtime_source: "synthetic",
               transport: :stdio,
               occurred_at_ms: 2,
               payload: %{token: "gap"}
             })

    assert {:ok, entries} = Reader.read_ordered(path)
    assert Enum.map(entries, & &1.event_seq) == [1]
  end

  defp journal_path(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-journal-writer-test-#{name}-#{System.unique_integer([:positive])}.jsonl"
      )

    File.rm(path)
    path
  end
end
