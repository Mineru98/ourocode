defmodule Ourocode.Runtime.OuroborosLogTailer do
  @moduledoc false

  alias Ourocode.Runtime.OuroborosLogLine

  @read_limit 65_536
  @doc false
  def canonical_log_path do
    home = System.user_home!()
    Path.join([home, ".ouroboros", "logs", "ouroboros.log"])
  rescue
    _exception -> nil
  end

  @doc false
  def file_size(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _error -> 0
    end
  end

  def file_size(_path), do: 0

  @doc false
  def tail(paths, offsets) when is_list(paths) and is_map(offsets) do
    paths
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce({[], offsets}, fn path, {acc, next_offsets} ->
      {lines, offset} = read_new_lines(path, Map.get(next_offsets, path))
      {acc ++ Enum.flat_map(lines, &parse_line/1), Map.put(next_offsets, path, offset)}
    end)
  end

  def tail(_paths, offsets), do: {[], offsets || %{}}

  @doc false
  def parse_line(line), do: OuroborosLogLine.parse(line)

  defp read_new_lines(path, nil) do
    size = file_size(path)
    start = max(size - @read_limit, 0)
    {read_from(path, start, size, drop_partial?: start > 0), size}
  end

  defp read_new_lines(path, offset) when is_integer(offset) do
    size = file_size(path)
    start = if offset <= size, do: offset, else: max(size - @read_limit, 0)
    {read_from(path, start, size, drop_partial?: offset > size), size}
  end

  defp read_new_lines(path, _offset), do: read_new_lines(path, nil)

  defp read_from(_path, start, size, _opts) when start >= size, do: []

  defp read_from(path, start, size, opts) do
    count = min(size - start, @read_limit)

    with {:ok, io} <- File.open(path, [:read, :binary]),
         {:ok, _pos} <- :file.position(io, start),
         data when is_binary(data) <- IO.binread(io, count) do
      File.close(io)

      data
      |> String.split(~r/\r?\n/, trim: true)
      |> maybe_drop_partial(Keyword.get(opts, :drop_partial?, false))
    else
      _error -> []
    end
  rescue
    _exception -> []
  end

  defp maybe_drop_partial([_partial | rest], true), do: rest
  defp maybe_drop_partial(lines, _drop?), do: lines
end
