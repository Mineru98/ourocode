defmodule Ourocode.Terminal.KeyModifiers do
  @moduledoc """
  Maps terminal modifier parameters to application key names.

  This covers the modified key encodings emitted by Kitty CSI-u and xterm
  modifyOtherKeys, plus left/right arrow word-navigation shortcuts.
  """

  @spec arrow(byte(), binary()) :: atom() | nil
  def arrow(final, params) when final in [?C, ?D] and is_binary(params) do
    with [_, modifier] <- split_ints(params),
         flags <- flags(modifier),
         true <- flags.alt or flags.ctrl or flags.super do
      if final == ?D, do: :alt_b, else: :alt_f
    else
      _other -> nil
    end
  end

  def arrow(_final, _params), do: nil

  @spec key(binary()) :: atom() | nil
  def key(params) when is_binary(params) do
    case split_ints(params) do
      [keycode, modifier] -> key(keycode, modifier)
      [27, modifier, keycode] -> key(keycode, modifier)
      _other -> nil
    end
  end

  defp key(127, modifier) do
    flags = flags(modifier)

    cond do
      flags.super -> :cmd_backspace
      flags.ctrl -> :ctrl_backspace
      true -> nil
    end
  end

  defp key(keycode, modifier) when keycode in [?+, ?=, ?-] do
    flags = flags(modifier)

    cond do
      flags.super and keycode in [?+, ?=] -> :cmd_plus
      flags.super and keycode == ?- -> :cmd_minus
      true -> nil
    end
  end

  defp key(_keycode, _modifier), do: nil

  defp split_ints(params) do
    params
    |> String.split(";")
    |> Enum.map(&parse_int/1)
  end

  defp flags(modifier) when is_integer(modifier) do
    bits = max(modifier - 1, 0)

    %{
      shift: :erlang.band(bits, 1) != 0,
      alt: :erlang.band(bits, 2) != 0,
      ctrl: :erlang.band(bits, 4) != 0,
      super: :erlang.band(bits, 8) != 0
    }
  end

  defp flags(_modifier), do: %{shift: false, alt: false, ctrl: false, super: false}

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end
end
