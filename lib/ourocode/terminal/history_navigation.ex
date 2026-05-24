defmodule Ourocode.Terminal.HistoryNavigation do
  @moduledoc """
  Pure prompt-history state transitions for the raw TUI.
  """

  @spec remember(map(), String.t(), pos_integer()) :: map()
  def remember(state, line, limit) when is_map(state) and is_binary(line) and is_integer(limit) do
    history =
      case List.first(Map.get(state, :history, [])) do
        ^line -> Map.get(state, :history, [])
        _other -> [line | Map.get(state, :history, [])] |> Enum.take(limit)
      end

    %{
      state
      | history: history,
        history_index: 0,
        history_draft: nil,
        ooo_cache: nil,
        ooo_cache_loaded_ms: nil
    }
  end

  @spec move(map(), -1 | 1) :: map()
  def move(state, direction) when is_map(state) and direction in [-1, 1] do
    history = Map.get(state, :history, [])
    count = length(history)
    history_index = Map.get(state, :history_index, 0)

    cond do
      count == 0 ->
        state

      direction == -1 ->
        index = min(history_index + 1, count)

        draft =
          if history_index == 0,
            do: Map.get(state, :buffer, ""),
            else: Map.get(state, :history_draft)

        buffer = Enum.at(history, index - 1, "")

        %{
          state
          | history_index: index,
            history_draft: draft,
            buffer: buffer,
            cursor: String.length(buffer)
        }

      direction == 1 and history_index > 1 ->
        index = history_index - 1
        buffer = Enum.at(history, index - 1, "")
        %{state | history_index: index, buffer: buffer, cursor: String.length(buffer)}

      direction == 1 and history_index == 1 ->
        buffer = Map.get(state, :history_draft) || ""

        %{
          state
          | history_index: 0,
            history_draft: nil,
            buffer: buffer,
            cursor: String.length(buffer)
        }

      true ->
        state
    end
  end

  @spec reset(map()) :: map()
  def reset(state) when is_map(state), do: %{state | history_index: 0, history_draft: nil}
end
