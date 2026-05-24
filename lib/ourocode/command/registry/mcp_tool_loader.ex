defmodule Ourocode.Command.Registry.McpToolLoader do
  @moduledoc false

  alias Ourocode.Command.Registry.McpToolEntry

  @spec entries(term()) :: [map()]
  def entries(nil), do: []

  def entries(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(&entries/1)
    |> Enum.sort_by(& &1.slash)
  end

  def entries(%{} = envelope) do
    cond do
      tools = McpToolEntry.tool_list(envelope) ->
        context = McpToolEntry.envelope_context(envelope)

        tools
        |> Enum.filter(&McpToolEntry.user_invocable?/1)
        |> Enum.map(&McpToolEntry.build(&1, context))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.slash)

      McpToolEntry.tool_entry?(envelope) and McpToolEntry.user_invocable?(envelope) ->
        envelope
        |> McpToolEntry.build(McpToolEntry.envelope_context(envelope))
        |> List.wrap()

      true ->
        []
    end
  end

  def entries(_entries), do: []
end
