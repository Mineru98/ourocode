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
      "| #{String.pad_trailing(entry.slash, 18)}",
      source_label(entry),
      summary(entry),
      usage_label(entry)
    ]
    |> Enum.reject(&(&1 in ["", nil]))
    |> Enum.join(" ")
  end

  defp source_label(%{source: :builtin}), do: "command"
  defp source_label(%{source: :guided_work}), do: "guided"
  defp source_label(%{source: :plugin}), do: "plugin"

  defp source_label(%{source: source}) when source in [:local, :bundled_skill, :dynamic_skill],
    do: "skill"

  defp source_label(_entry), do: "tool"

  defp usage_label(%{args: []}), do: ""

  defp usage_label(%{args: args}) do
    rendered =
      args
      |> Enum.map(fn arg ->
        name = Map.get(arg, :name, "arg")
        if Map.get(arg, :required?, false), do: "<#{name}>", else: "[#{name}]"
      end)
      |> Enum.join(" ")

    rendered
  end

  defp summary(%{summary: summary}) when is_binary(summary) and summary != "" do
    summary
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\bDo NOT use:.*$/i, "")
    |> String.replace(~r/\bTriggers?:.*$/i, "")
    |> String.trim()
  end

  defp summary(_entry), do: "Run this command"
end
