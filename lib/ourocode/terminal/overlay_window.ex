defmodule Ourocode.Terminal.OverlayWindow do
  @moduledoc """
  Selects the visible slice of an overlay list around the active index.
  """

  @spec visible([term()], integer(), pos_integer()) ::
          {non_neg_integer(), [{term(), non_neg_integer()}]}
  def visible(items, _index, _limit) when items == [], do: {0, []}

  def visible(items, index, limit) when is_list(items) and is_integer(index) and limit > 0 do
    total = length(items)
    idx = max(min(index, total - 1), 0)

    offset =
      cond do
        total <= limit -> 0
        idx < limit -> 0
        true -> min(idx - limit + 1, total - limit)
      end

    {offset, items |> Enum.slice(offset, limit) |> Enum.with_index(offset)}
  end
end
