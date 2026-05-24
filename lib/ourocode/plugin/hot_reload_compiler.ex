defmodule Ourocode.Plugin.HotReloadCompiler do
  @moduledoc """
  Validates and compiles plugin source files for hot reload.

  The boundary owns reload state transitions. This module owns the smaller
  side-effect of compiling changed source files under allowed plugin roots.
  """

  alias Ourocode.Plugin.PathPolicy

  @doc """
  Compiles every path in `:compile_paths`, stopping at the first failure.
  """
  @spec compile_changed_sources(keyword()) :: :ok | {:error, term()}
  def compile_changed_sources(opts) when is_list(opts) do
    opts
    |> Keyword.get(:compile_paths, [])
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case compile_source(path, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Validates a source path with `PathPolicy`, then compiles it.
  """
  @spec compile_source(term(), keyword()) :: :ok | {:error, term()}
  def compile_source(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, source_path} <- PathPolicy.validate(path, opts) do
      Code.compile_file(source_path)
      :ok
    end
  rescue
    exception -> {:error, {:compile_failed, path, Exception.message(exception)}}
  end

  def compile_source(path, _opts), do: {:error, {:invalid_compile_path, path}}
end
