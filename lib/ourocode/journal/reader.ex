defmodule Ourocode.Journal.Reader do
  @moduledoc false

  alias Ourocode.Journal.Codec

  @type entry :: map()

  @spec read(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path) do
      contents
      |> String.split(["\r\n", "\n", "\r"], trim: true)
      |> decode_lines()
    end
  end

  @spec read_ordered(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def read_ordered(path) when is_binary(path) do
    with {:ok, entries} <- read(path) do
      case verify_no_event_seq_gaps(entries) do
        :ok -> {:ok, entries}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec read_existing_entries(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def read_existing_entries(path) when is_binary(path) do
    case read(path) do
      {:ok, entries} -> {:ok, entries}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec verify_no_event_seq_gaps([entry()]) :: :ok | {:error, term()}
  def verify_no_event_seq_gaps(entries) when is_list(entries) do
    seqs = Enum.map(entries, &Map.get(&1, :event_seq))

    expected =
      case seqs do
        [] -> []
        [first | _] when is_integer(first) -> Enum.to_list(first..(first + length(seqs) - 1)//1)
        _ -> []
      end

    if seqs == expected do
      :ok
    else
      {:error, {:event_seq_gap, expected, seqs}}
    end
  end

  defp decode_lines(lines) do
    entries =
      Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
        case Ourocode.Json.decode(line) do
          {:ok, record} when is_map(record) -> {:cont, {:ok, [Codec.decode(record) | acc]}}
          {:ok, _other} -> {:halt, {:error, {:invalid_journal_record, line}}}
          {:error, reason} -> {:halt, {:error, {:invalid_journal_json, reason}}}
        end
      end)

    case entries do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end
end
