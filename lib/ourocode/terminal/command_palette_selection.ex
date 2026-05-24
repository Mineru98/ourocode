defmodule Ourocode.Terminal.CommandPaletteSelection do
  @moduledoc """
  Registry-backed command palette selection resolution.

  Display rendering and selection parsing have different failure modes. This
  module keeps index, slash, and name resolution out of the palette renderer.
  """

  alias Ourocode.Command.Registry

  @doc """
  Resolves one palette selection against the merged registry.
  """
  @spec select(map(), integer() | String.t()) :: {:ok, map()} | {:error, term()}
  def select(registry, selection) when is_map(registry) do
    with {:ok, normalized_selection} <- normalize_selection(selection) do
      resolve_selection(registry, normalized_selection)
    end
  end

  defp normalize_selection(selection) when is_integer(selection) and selection > 0,
    do: {:ok, {:index, selection}}

  defp normalize_selection(selection) when is_binary(selection) do
    trimmed = String.trim(selection)

    cond do
      trimmed == "" ->
        {:error, :selection_required}

      match?({_, ""}, Integer.parse(trimmed)) ->
        {index, ""} = Integer.parse(trimmed)
        normalize_selection(index)

      String.starts_with?(trimmed, "/") ->
        {:ok, {:slash, trimmed}}

      true ->
        {:ok, {:name, trimmed}}
    end
  end

  defp normalize_selection(_selection), do: {:error, :invalid_selection}

  defp resolve_selection(registry, {:index, index}) do
    case registry |> Registry.entries() |> Enum.at(index - 1) do
      nil -> {:error, {:selection_out_of_range, index}}
      entry -> {:ok, entry}
    end
  end

  defp resolve_selection(registry, {:slash, slash}) do
    case Registry.fetch(registry, slash) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_selection, slash}}
    end
  end

  defp resolve_selection(registry, {:name, name}) do
    normalized_name = normalize_name(name)

    registry
    |> Registry.entries()
    |> Enum.find(&(normalize_name(Map.get(&1, :name, "")) == normalized_name))
    |> case do
      nil -> {:error, {:unknown_selection, name}}
      entry -> {:ok, entry}
    end
  end

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s_]+/, "-")
  end
end
