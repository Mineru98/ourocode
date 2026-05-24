defmodule Ourocode.Runtime.InterviewRouter.ToolSandbox do
  @moduledoc false

  @max_read_bytes 32_768
  @max_glob_hits 100
  @max_grep_bytes 8_192
  @grep_timeout_ms 5_000

  @spec run(atom(), String.t(), Path.t()) :: {String.t(), String.t()}
  def run(:read, rel, root) do
    case safe_path(rel, root) do
      {:ok, abs} ->
        case File.read(abs) do
          {:ok, bin} -> {"READ #{rel}", cap_bytes(bin, @max_read_bytes)}
          {:error, reason} -> {"READ #{rel}", "error: #{:file.format_error(reason)}"}
        end

      {:error, why} ->
        {"READ #{rel}", "rejected: #{why}"}
    end
  end

  def run(:glob, pat, root) do
    case safe_relative?(pat) do
      :ok ->
        hits =
          root
          |> Path.join(pat)
          |> Path.wildcard()
          |> Enum.map(&Path.relative_to(&1, root))
          |> Enum.take(@max_glob_hits)

        body = if hits == [], do: "(no matches)", else: Enum.join(hits, "\n")
        {"GLOB #{pat}", body}

      {:error, why} ->
        {"GLOB #{pat}", "rejected: #{why}"}
    end
  end

  def run(:grep, arg, root) do
    {pattern, glob} = split_grep_arg(arg)

    cond do
      pattern == "" ->
        {"GREP #{arg}", "rejected: empty pattern"}

      glob != nil and match?({:error, _}, safe_relative?(glob)) ->
        {"GREP #{arg}", "rejected: unsafe glob"}

      true ->
        {"GREP #{arg}", bounded_grep(pattern, glob, root)}
    end
  end

  def run(_tool, arg, _root), do: {"UNKNOWN #{inspect(arg)}", "rejected: unknown tool"}

  defp bounded_grep(pattern, glob, root) do
    args =
      ["-rnI", "--"]
      |> then(fn base -> if glob, do: ["--include=" <> glob | base], else: base end)
      |> Kernel.++([pattern, "."])

    task =
      Task.async(fn ->
        System.cmd("grep", args, cd: root, stderr_to_stdout: true)
      end)

    case Task.yield(task, @grep_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, status}} when status in [0, 1] ->
        if String.trim(out) == "", do: "(no matches)", else: cap_bytes(out, @max_grep_bytes)

      {:ok, {out, _status}} ->
        "error: " <> cap_bytes(out, 256)

      _timeout_or_crash ->
        "error: grep timed out"
    end
  rescue
    _exception -> "error: grep unavailable"
  end

  defp split_grep_arg(arg) do
    case String.split(String.trim(arg), ~r/\s+/, parts: 2) do
      [pattern] -> {pattern, nil}
      [pattern, glob] -> {pattern, String.trim(glob)}
      _none -> {"", nil}
    end
  end

  # Default-deny, resolve-then-contain: reject hostile literals before
  # resolving, then check containment of the resolved path. This closes the
  # TOCTOU/symlink-escape hole `Path.expand` alone leaves open: a link inside
  # the project pointing out would otherwise pass a pure string-prefix check.
  defp safe_path(rel, root) do
    with :ok <- safe_relative?(rel) do
      root = Path.expand(root)
      abs = Path.expand(rel, root)

      cond do
        not contained?(abs, root) -> {:error, "path escapes project root"}
        symlink_on_path?(rel, root) -> {:error, "symlinked path not allowed in sandbox"}
        true -> {:ok, abs}
      end
    end
  end

  defp contained?(abs, root), do: abs == root or String.starts_with?(abs, root <> "/")

  # Walk only the `rel` portion under `root`; if any existing component is a
  # symlink, reject. A read-only interview sandbox never needs to follow
  # links, so "no symlinks at all below root" is a stronger, simpler floor
  # than realpath-then-contain (and root's own ancestors stay out of scope).
  defp symlink_on_path?(rel, root) do
    rel
    |> Path.split()
    |> Enum.reduce_while(root, fn part, acc ->
      next = Path.join(acc, part)

      case :file.read_link(next) do
        {:ok, _target} -> {:halt, :symlink}
        _not_a_link -> {:cont, next}
      end
    end)
    |> Kernel.==(:symlink)
  end

  defp safe_relative?(path) when is_binary(path) do
    cond do
      path == "" -> {:error, "empty path"}
      String.contains?(path, <<0>>) -> {:error, "null byte"}
      String.starts_with?(path, "/") -> {:error, "absolute path"}
      String.starts_with?(path, "~") -> {:error, "home expansion"}
      String.contains?(path, ["$", "`"]) -> {:error, "shell expansion"}
      String.starts_with?(path, ["%", "="]) -> {:error, "shell expansion"}
      String.contains?(path, "\\") -> {:error, "backslash/UNC path"}
      ".." in Path.split(path) -> {:error, "parent escape"}
      true -> :ok
    end
  end

  defp safe_relative?(_path), do: {:error, "invalid path"}

  defp cap_bytes(bin, limit) when byte_size(bin) <= limit, do: bin

  defp cap_bytes(bin, limit) do
    binary_part(bin, 0, limit) <> "\n...[truncated at #{limit} bytes]"
  end
end
