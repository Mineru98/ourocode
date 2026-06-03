defmodule Ourocode.Terminal.KeySgrMouse do
  @moduledoc """
  Parser for SGR mouse reports inside CSI terminal sequences.

  SGR reports have the shape `ESC [ < b ; x ; y (M|m)`.
  """

  import Bitwise

  alias Ourocode.Terminal.KeyEvent

  @type result :: {:ok, map(), binary()} | :incomplete | :ignore_one

  @spec parse(binary()) :: result()
  def parse(rest) when is_binary(rest), do: parse(rest, [])

  defp parse(<<d, rest::binary>>, acc) when d in ?0..?9 or d == ?;,
    do: parse(rest, [d | acc])

  defp parse(<<t, rest::binary>>, acc) when t in [?M, ?m] do
    {:ok, mouse_event(acc |> Enum.reverse() |> IO.iodata_to_binary(), t), rest}
  end

  defp parse(<<>>, _acc), do: :incomplete
  defp parse(_other, _acc), do: :ignore_one

  defp mouse_event(spec, final) do
    case String.split(spec, ";") do
      [b, x, y] -> classify(parse_int(b), parse_int(x), parse_int(y), final)
      _other -> KeyEvent.mouse(:other, nil, nil)
    end
  end

  defp classify(64, x, y, _final), do: KeyEvent.mouse(:wheel_up, x, y)
  defp classify(65, x, y, _final), do: KeyEvent.mouse(:wheel_down, x, y)
  defp classify(_button, x, y, ?m), do: KeyEvent.mouse(:mouse_release, x, y)

  defp classify(button, x, y, ?M) when is_integer(button) do
    cond do
      (button &&& 32) == 32 -> KeyEvent.mouse(:mouse_move, x, y)
      (button &&& 3) == 0 -> KeyEvent.mouse(:mouse_down, x, y)
      true -> KeyEvent.mouse(:other, x, y)
    end
  end

  defp classify(_button, _x, _y, _final), do: KeyEvent.mouse(:other, nil, nil)

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end
end
