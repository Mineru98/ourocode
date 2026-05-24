defmodule Ourocode.Journal.ReaderTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.Reader

  test "reads decoded JSONL records in file order" do
    path = journal_path("reader-order")

    File.write!(path, [
      ~s({"event_seq":1,"type":"first"}\n),
      ~s({"event_seq":2,"type":"second"}\n)
    ])

    assert {:ok, [%{event_seq: 1, type: "first"}, %{event_seq: 2, type: "second"}]} =
             Reader.read(path)
  end

  test "read_ordered rejects sequence gaps" do
    path = journal_path("reader-gap")

    File.write!(path, [
      ~s({"event_seq":3,"type":"first"}\n),
      ~s({"event_seq":5,"type":"second"}\n)
    ])

    assert Reader.read_ordered(path) == {:error, {:event_seq_gap, [3, 4], [3, 5]}}
  end

  test "read_existing_entries treats a missing journal as empty" do
    assert Reader.read_existing_entries(journal_path("missing")) == {:ok, []}
  end

  defp journal_path(name) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")

    File.rm(path)
    path
  end
end
