defmodule Ourocode.Plugin.PathPolicy do
  @moduledoc """
  Validates plugin paths against configured allowed roots.

  The policy resolves both plugin paths and allowed roots before comparison,
  including existing symlinked path segments, so relative plugin paths can be
  accepted without relying on string-prefix checks.
  """

  @app :ourocode

  @type validation_error :: :plugin_path_not_allowed | :invalid_allowed_plugin_roots

  @doc """
  Expands and validates a plugin path against configured allowed roots.

  Options:

    * `:allowed_roots` - allowed plugin root directories. Defaults to
      `Application.get_env(:ourocode, :plugin_allowed_roots, [])`.
    * `:base_dir` - base directory used to expand relative plugin paths and
      relative allowed roots. Defaults to the current working directory.
  """
  @spec validate(Path.t(), keyword()) :: {:ok, String.t()} | {:error, validation_error()}
  def validate(plugin_path, opts \\ []) when is_binary(plugin_path) and is_list(opts) do
    base_dir = Keyword.get(opts, :base_dir, File.cwd!())
    expanded_path = expand(plugin_path, base_dir)

    with {:ok, allowed_roots} <- allowed_roots(opts),
         true <- path_allowed?(expanded_path, allowed_roots, base_dir) do
      {:ok, expanded_path}
    else
      false -> {:error, :plugin_path_not_allowed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp allowed_roots(opts) do
    roots =
      Keyword.get(opts, :allowed_roots, Application.get_env(@app, :plugin_allowed_roots, []))

    if is_list(roots) and Enum.all?(roots, &is_binary/1) do
      {:ok, roots}
    else
      {:error, :invalid_allowed_plugin_roots}
    end
  end

  defp path_allowed?(_plugin_path, [], _base_dir), do: false

  defp path_allowed?(plugin_path, allowed_roots, base_dir) do
    canonical_path = canonical_path(plugin_path)

    Enum.any?(allowed_roots, fn root ->
      path_under_root?(canonical_path, canonical_path(expand(root, base_dir)))
    end)
  end

  defp path_under_root?(path, root) do
    path_parts = Path.split(path)
    root_parts = Path.split(root)

    length(path_parts) >= length(root_parts) and
      Enum.take(path_parts, length(root_parts)) == root_parts
  end

  defp expand(path, base_dir) do
    Path.expand(path, base_dir)
  end

  defp canonical_path(path) do
    expanded_path = Path.expand(path)
    parts = Path.split(expanded_path)

    case deepest_existing_prefix(parts) do
      {existing_parts, remaining_parts} ->
        Path.join([realpath(Path.join(existing_parts)) | remaining_parts])

      nil ->
        expanded_path
    end
  end

  defp realpath(path) do
    case System.find_executable("realpath") do
      nil ->
        path

      executable ->
        case System.cmd(executable, [path], stderr_to_stdout: true) do
          {resolved, 0} -> String.trim_trailing(resolved)
          {_output, _status} -> path
        end
    end
  end

  defp deepest_existing_prefix(parts) do
    Enum.reduce_while(length(parts)..1//-1, nil, fn count, _acc ->
      existing_parts = Enum.take(parts, count)

      if File.exists?(Path.join(existing_parts)) do
        {:halt, {existing_parts, Enum.drop(parts, count)}}
      else
        {:cont, nil}
      end
    end)
  end
end
