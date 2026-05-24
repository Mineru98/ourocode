defmodule Ourocode.Terminal.KeySgrMouse do
  @moduledoc """
  Parser for SGR mouse reports inside CSI terminal sequences.

  SGR reports have the shape `ESC [ < b ; x ; y (M|m)`. The terminal input
  path only surfaces wheel up/down events today; other reports are consumed as
  `:other` so the higher-level decoder can keep byte ordering intact.
  """

  alias Ourocode.Terminal.KeyEvent

  @type result :: {:ok, map(), binary()} | :incomplete | :ignore_one

  @spec parse(binary()) :: result()
  def parse(rest) when is_binary(rest), do: parse(rest, [])

  defp parse(<<d, rest::binary>>, acc) when d in ?0..?9 or d == ?;,
    do: parse(rest, [d | acc])

  defp parse(<<t, rest::binary>>, acc) when t in [?M, ?m] do
    {:ok, mouse_event(acc |> Enum.reverse() |> IO.iodata_to_binary()), rest}
  end

  defp parse(<<>>, _acc), do: :incomplete
  defp parse(_other, _acc), do: :ignore_one

  defp mouse_event(spec) do
    case String.split(spec, ";") do
      [b, x, y] -> wheel(parse_int(b), parse_int(x), parse_int(y))
      _other -> KeyEvent.mouse(:other, nil, nil)
    end
  end

  defp wheel(64, x, y), do: KeyEvent.mouse(:wheel_up, x, y)
  defp wheel(65, x, y), do: KeyEvent.mouse(:wheel_down, x, y)
  defp wheel(_button, _x, _y), do: KeyEvent.mouse(:other, nil, nil)

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end
end
