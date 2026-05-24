defmodule Ourocode.Terminal.CommandPaletteEntry do
  @moduledoc """
  Command palette entry projection and line formatting.
  """

  @doc """
  Projects a normalized command registry entry into the compact palette model.
  """
  @spec model(map()) :: map()
  def model(entry) when is_map(entry) do
    %{
      id: Map.fetch!(entry, :id),
      slash: Map.fetch!(entry, :slash),
      name: Map.fetch!(entry, :name),
      summary: Map.get(entry, :summary, ""),
      source: Map.fetch!(entry, :source),
      source_id: Map.fetch!(entry, :source_id),
      category: Map.fetch!(entry, :category),
      aliases: Map.get(entry, :aliases, []),
      args: Map.get(entry, :args, []),
      availability: Map.get(entry, :availability, :available),
      runnable?: Map.get(entry, :runnable?, true)
    }
  end

  @doc """
  Formats a projected palette entry as one stable terminal line.
  """
  @spec line(map()) :: String.t()
  def line(entry) when is_map(entry) do
    [
      "| #{entry.slash}",
      "[#{entry.source}/#{entry.category}]",
      availability_label(entry),
      args_label(entry),
      aliases_label(entry),
      summary_label(entry)
    ]
    |> Enum.reject(&(&1 in ["", nil]))
    |> Enum.join(" ")
  end

  defp availability_label(%{availability: :available, runnable?: true}), do: ""

  defp availability_label(%{availability: availability, runnable?: runnable?}) do
    "availability=#{availability} runnable?=#{runnable?}"
  end

  defp args_label(%{args: []}), do: ""

  defp args_label(%{args: args}) do
    rendered =
      args
      |> Enum.map(fn arg ->
        suffix = if Map.get(arg, :required?, false), do: "*", else: ""
        "#{Map.get(arg, :name, "arg")}#{suffix}"
      end)
      |> Enum.join(",")

    "args=#{rendered}"
  end

  defp aliases_label(%{aliases: []}), do: ""
  defp aliases_label(%{aliases: aliases}), do: "aliases=#{Enum.join(aliases, ",")}"

  defp summary_label(%{summary: ""}), do: ""
  defp summary_label(%{summary: summary}), do: ~s(summary="#{summary}")
end
