defmodule Ourocode.Plugin.Checksum do
  @moduledoc """
  Deterministic SHA-256 checksums for plugin directories.
  """

  @spec compute(Path.t()) :: {:ok, String.t()} | {:error, :plugin_checksum_unavailable}
  def compute(plugin_path) when is_binary(plugin_path) do
    with {:ok, files} <- regular_plugin_files(plugin_path) do
      result =
        files
        |> Enum.sort_by(& &1.relative_path)
        |> Enum.reduce_while({:ok, :crypto.hash_init(:sha256)}, fn file, {:ok, context} ->
          case File.read(file.absolute_path) do
            {:ok, contents} ->
              next_context =
                context
                |> :crypto.hash_update(file.relative_path)
                |> :crypto.hash_update(<<0>>)
                |> :crypto.hash_update(contents)
                |> :crypto.hash_update(<<0>>)

              {:cont, {:ok, next_context}}

            {:error, _reason} ->
              {:halt, {:error, :plugin_checksum_unavailable}}
          end
        end)

      case result do
        {:ok, context} ->
          {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp regular_plugin_files(plugin_path) do
    case File.ls(plugin_path) do
      {:ok, entries} ->
        with {:ok, absolute_paths} <- collect_regular_plugin_files(plugin_path, entries) do
          files =
            Enum.map(absolute_paths, fn absolute_path ->
              %{
                absolute_path: absolute_path,
                relative_path: Path.relative_to(absolute_path, plugin_path)
              }
            end)

          {:ok, files}
        end

      {:error, _reason} ->
        {:error, :plugin_checksum_unavailable}
    end
  end

  defp collect_regular_plugin_files(parent_path, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, files} ->
      path = Path.join(parent_path, entry)

      cond do
        File.regular?(path) ->
          {:cont, {:ok, [path | files]}}

        File.dir?(path) ->
          case File.ls(path) do
            {:ok, child_entries} ->
              case collect_regular_plugin_files(path, child_entries) do
                {:ok, child_files} -> {:cont, {:ok, child_files ++ files}}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            {:error, _reason} ->
              {:halt, {:error, :plugin_checksum_unavailable}}
          end

        true ->
          {:cont, {:ok, files}}
      end
    end)
  end
end
