defmodule Ourocode.Terminal.RendererLoginCard do
  @moduledoc """
  Focal login card renderer for interactive device authorization.
  """

  alias Ourocode.Terminal.Screen

  @left_margin 2

  @spec draw(Screen.t(), pos_integer(), non_neg_integer(), non_neg_integer(), map()) :: Screen.t()
  def draw(screen, width, top, bottom, login) when is_map(login) do
    card_w = min(54, width - 2 * @left_margin)
    card_h = 7
    x = div(width - card_w, 2)
    y = top + max(div(bottom - top + 1 - card_h, 2), 0)
    code = Map.get(login, :code, "------")
    url = Map.get(login, :url, "")

    screen
    |> Screen.box(x, y, card_w, card_h, "Connect ChatGPT", :accent)
    |> center(y + 2, width, url, :dim)
    |> center(y + 4, width, code, :brand)
    |> center(y + card_h, width, "waiting for approval - Ctrl-C to cancel", :muted)
  end

  defp center(screen, y, width, text, style) do
    x = max(div(width - Screen.text_width(text), 2), 0)
    Screen.put_text(screen, x, y, text, style)
  end
end
