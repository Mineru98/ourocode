defmodule Ourocode.Runtime.OuroborosLogTailer do
  @moduledoc false

  @read_limit 65_536

  @interesting_prefixes [
    "auto",
    "interview",
    "mcp.tool.interview",
    "mcp.tool.generate_seed",
    "mcp.tool.execute_seed",
    "seed",
    "execution",
    "evolve",
    "ralph"
  ]

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
  def parse_line(line) when is_binary(line) do
    line = line |> strip_ansi() |> String.trim()

    cond do
      line == "" ->
        []

      String.starts_with?(line, "[auto]") ->
        [line |> String.replace_prefix("[auto]", "auto:") |> normalize_spaces()]

      true ->
        parse_structured_line(line)
    end
  end

  def parse_line(_line), do: []

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

  defp parse_structured_line(line) do
    case Regex.run(~r/^\S+\s+\[\s*([a-zA-Z]+)\s*\]\s+([^\s]+)\s*(.*)$/, line) do
      [_all, level, event, kv] ->
        if interesting_event?(event), do: [format_event(level, event, parse_fields(kv))], else: []

      _no_match ->
        []
    end
  end

  defp interesting_event?(event) do
    Enum.any?(@interesting_prefixes, fn prefix ->
      event == prefix or String.starts_with?(event, prefix <> ".")
    end)
  end

  defp format_event(level, event, fields) do
    level = String.downcase(level)

    base =
      case event do
        "interview.started" ->
          compact_join([
            "interview started",
            session_part(fields, "interview_id"),
            context_part(fields),
            brownfield_part(fields)
          ])

        "interview.question_generated" ->
          compact_join([
            round_part(fields),
            "question generated",
            chars_part(fields, "question_length")
          ])

        "interview.response_recorded" ->
          compact_join([
            round_part(fields),
            "answer recorded",
            chars_part(fields, "response_length")
          ])

        "interview.state_saved" ->
          compact_join(["state saved", session_part(fields, "interview_id")])

        "mcp.tool.interview.started" ->
          compact_join(["mcp interview started", session_part(fields, "session_id")])

        "mcp.tool.interview.question_asked" ->
          compact_join(["mcp question asked", session_part(fields, "session_id")])

        "mcp.tool.interview.response_recorded" ->
          compact_join(["mcp answer recorded", session_part(fields, "session_id")])

        "mcp.tool.interview.error" ->
          compact_join(["mcp interview error", Map.get(fields, "error")])

        _other ->
          fallback_event(event, fields)
      end

    case level do
      "warning" -> "warning: " <> base
      "error" -> "error: " <> base
      _info -> base
    end
    |> normalize_spaces()
  end

  defp parse_fields(kv) when is_binary(kv) do
    ~r/([A-Za-z_][A-Za-z0-9_]*)=(?:"([^"]*)"|'([^']*)'|([^\s]+))/
    |> Regex.scan(kv)
    |> Map.new(fn
      [_all, key, double, "", ""] -> {key, double}
      [_all, key, "", single, ""] -> {key, single}
      [_all, key, "", "", bare] -> {key, bare}
    end)
  end

  defp compact_join(parts) do
    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp session_part(fields, key) do
    case Map.get(fields, key) do
      nil -> nil
      "" -> nil
      id -> "session " <> short_id(id)
    end
  end

  defp round_part(fields) do
    case Map.get(fields, "round_number") do
      nil -> nil
      "" -> nil
      round -> "round " <> round
    end
  end

  defp chars_part(fields, key) do
    case Map.get(fields, key) do
      nil -> nil
      "" -> nil
      chars -> chars <> " chars"
    end
  end

  defp context_part(fields), do: chars_part(fields, "initial_context_length")

  defp brownfield_part(fields) do
    case Map.get(fields, "is_brownfield") do
      "True" -> "brownfield"
      "true" -> "brownfield"
      "False" -> "new project"
      "false" -> "new project"
      _other -> nil
    end
  end

  defp fallback_event(event, fields) do
    details =
      fields
      |> Enum.reject(fn {key, _value} -> key in ["filename", "lineno", "file_path"] end)
      |> Enum.take(3)
      |> Enum.map_join(" · ", fn {key, value} -> "#{key} #{value}" end)

    compact_join([event, details])
  end

  defp short_id(id) when is_binary(id) do
    id
    |> String.replace_prefix("interview_", "")
    |> case do
      <<prefix::binary-size(15), _rest::binary>> = full when byte_size(full) > 15 ->
        prefix <> "..."

      short ->
        short
    end
  end

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")
  defp normalize_spaces(text), do: String.replace(text, ~r/\s+/, " ") |> String.trim()
end
