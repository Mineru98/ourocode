defmodule Ourocode.Terminal.KeyReader do
  @moduledoc """
  Pure raw-terminal byte/ANSI stream decoder.

  Raw mode delivers keystrokes as bytes (and multi-byte ANSI escape
  sequences) rather than cooked lines. This module converts an arbitrary
  byte buffer into ordered key events, returning any trailing bytes that
  form an incomplete escape or UTF-8 sequence so the caller can prepend
  them to the next read. It owns no IO and no process state, which keeps
  the terminal driver's input path fully unit-testable.
  """

  @type key ::
          :enter
          | :backspace
          | :tab
          | :escape
          | :ctrl_c
          | :ctrl_a
          | :ctrl_b
          | :ctrl_d
          | :ctrl_e
          | :ctrl_f
          | :ctrl_g
          | :ctrl_k
          | :ctrl_n
          | :ctrl_p
          | :ctrl_u
          | :ctrl_w
          | :ctrl_y
          | :alt_b
          | :alt_d
          | :alt_f
          | :alt_y
          | :cmd_backspace
          | :ctrl_backspace
          | :cmd_plus
          | :cmd_minus
          | :up
          | :down
          | :left
          | :right
          | :home
          | :end
          | :delete
          | :page_up
          | :page_down
          | :paste
          | :char

  @type event :: %{
          required(:type) => :key,
          required(:key) => key(),
          required(:char) => String.t() | nil
        }

  @doc """
  Decodes a raw byte buffer into ordered key events.

  Returns `{events, rest}` where `rest` is the unconsumed tail that forms
  an incomplete escape or UTF-8 sequence and must be prepended to the next
  decode call.
  """
  @spec decode(binary()) :: {[event()], binary()}
  def decode(buffer) when is_binary(buffer), do: decode(buffer, [])

  defp decode(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  # Carriage return / line feed -> submit.
  defp decode(<<c, rest::binary>>, acc) when c in [10, 13],
    do: decode(rest, [key(:enter) | acc])

  defp decode(<<9, rest::binary>>, acc), do: decode(rest, [key(:tab) | acc])

  defp decode(<<1, rest::binary>>, acc), do: decode(rest, [key(:ctrl_a) | acc])
  defp decode(<<2, rest::binary>>, acc), do: decode(rest, [key(:ctrl_b) | acc])
  defp decode(<<3, rest::binary>>, acc), do: decode(rest, [key(:ctrl_c) | acc])
  defp decode(<<4, rest::binary>>, acc), do: decode(rest, [key(:ctrl_d) | acc])
  defp decode(<<5, rest::binary>>, acc), do: decode(rest, [key(:ctrl_e) | acc])
  defp decode(<<6, rest::binary>>, acc), do: decode(rest, [key(:ctrl_f) | acc])
  defp decode(<<7, rest::binary>>, acc), do: decode(rest, [key(:ctrl_g) | acc])
  defp decode(<<11, rest::binary>>, acc), do: decode(rest, [key(:ctrl_k) | acc])
  defp decode(<<14, rest::binary>>, acc), do: decode(rest, [key(:ctrl_n) | acc])
  defp decode(<<16, rest::binary>>, acc), do: decode(rest, [key(:ctrl_p) | acc])
  defp decode(<<21, rest::binary>>, acc), do: decode(rest, [key(:ctrl_u) | acc])
  defp decode(<<23, rest::binary>>, acc), do: decode(rest, [key(:ctrl_w) | acc])
  defp decode(<<25, rest::binary>>, acc), do: decode(rest, [key(:ctrl_y) | acc])

  # DEL (127) and BS (8) both map to backspace across terminals.
  defp decode(<<c, rest::binary>>, acc) when c in [8, 127],
    do: decode(rest, [key(:backspace) | acc])

  # CSI escape sequences: ESC [ ...
  defp decode(<<27, ?[, rest::binary>> = seq, acc) do
    case csi(rest) do
      {:ok, key, tail} -> decode(tail, [key | acc])
      :incomplete -> {Enum.reverse(acc), seq}
      :ignore_one -> decode(rest, acc)
    end
  end

  # SS3 escape sequences: ESC O <A-D> (application cursor mode).
  defp decode(<<27, ?O, c, rest::binary>>, acc) do
    case arrow(c) do
      {:ok, key} -> decode(rest, [key(key) | acc])
      :error -> decode(rest, acc)
    end
  end

  # A lone ESC with nothing after it yet — could still grow into CSI/SS3.
  defp decode(<<27>>, acc), do: {Enum.reverse(acc), <<27>>}
  defp decode(<<27, ?O>>, acc), do: {Enum.reverse(acc), <<27, ?O>>}

  # Alt/Meta word editing shortcuts. Many terminals encode Option/Meta as
  # ESC + printable byte when enhanced keyboard mode is not enabled.
  defp decode(<<27, ?b, rest::binary>>, acc), do: decode(rest, [key(:alt_b) | acc])
  defp decode(<<27, ?B, rest::binary>>, acc), do: decode(rest, [key(:alt_b) | acc])
  defp decode(<<27, ?d, rest::binary>>, acc), do: decode(rest, [key(:alt_d) | acc])
  defp decode(<<27, ?D, rest::binary>>, acc), do: decode(rest, [key(:alt_d) | acc])
  defp decode(<<27, ?f, rest::binary>>, acc), do: decode(rest, [key(:alt_f) | acc])
  defp decode(<<27, ?F, rest::binary>>, acc), do: decode(rest, [key(:alt_f) | acc])
  defp decode(<<27, ?y, rest::binary>>, acc), do: decode(rest, [key(:alt_y) | acc])
  defp decode(<<27, ?Y, rest::binary>>, acc), do: decode(rest, [key(:alt_y) | acc])

  # ESC followed by a non-sequence byte: treat ESC as a standalone key and
  # continue decoding from the following byte.
  defp decode(<<27, rest::binary>>, acc), do: decode(rest, [key(:escape) | acc])

  # Other C0 control bytes are not surfaced as editable input.
  defp decode(<<c, rest::binary>>, acc) when c < 32,
    do: decode(rest, acc)

  # Printable ASCII.
  defp decode(<<c, rest::binary>>, acc) when c >= 32 and c < 127,
    do: decode(rest, [char(<<c>>) | acc])

  # UTF-8 multi-byte: emit one grapheme when complete, otherwise buffer the
  # incomplete lead bytes for the next read.
  defp decode(<<c, _::binary>> = buffer, acc) when c >= 0xC0 do
    case utf8_take(buffer) do
      {:ok, grapheme, rest} -> decode(rest, [char(grapheme) | acc])
      :incomplete -> {Enum.reverse(acc), buffer}
      :invalid -> decode(binary_part(buffer, 1, byte_size(buffer) - 1), acc)
    end
  end

  # Stray UTF-8 continuation byte with no lead — drop it.
  defp decode(<<_c, rest::binary>>, acc), do: decode(rest, acc)

  defp csi(rest) do
    case rest do
      <<?<, tail::binary>> -> sgr_mouse(tail, [])
      <<?2, ?0, ?0, ?~, tail::binary>> -> bracketed_paste(tail)
      _other -> csi_sequence(rest, "")
    end
  end

  defp bracketed_paste(tail) do
    marker = "\e[201~"

    case :binary.match(tail, marker) do
      {idx, _len} ->
        text = binary_part(tail, 0, idx)

        rest =
          binary_part(tail, idx + byte_size(marker), byte_size(tail) - idx - byte_size(marker))

        {:ok, %{type: :key, key: :paste, char: text}, rest}

      :nomatch ->
        :incomplete
    end
  end

  defp csi_sequence(<<>>, _params), do: :incomplete

  defp csi_sequence(<<final, tail::binary>>, params)
       when final in [?A, ?B, ?C, ?D, ?H, ?F, ?~, ?u] do
    csi_final(final, params, tail)
  end

  defp csi_sequence(<<d, tail::binary>>, params) when d in ?0..?9 or d == ?;,
    do: csi_sequence(tail, params <> <<d>>)

  defp csi_sequence(_other, _params), do: :ignore_one

  defp csi_final(final, params, tail) when final in [?A, ?B, ?C, ?D] do
    case modified_arrow(final, params) do
      nil ->
        case arrow(final) do
          {:ok, name} -> {:ok, key(name), tail}
          :error -> :ignore_one
        end

      name ->
        {:ok, key(name), tail}
    end
  end

  defp csi_final(?H, _params, tail), do: {:ok, key(:home), tail}
  defp csi_final(?F, _params, tail), do: {:ok, key(:end), tail}

  defp csi_final(?u, params, tail) do
    case modified_key(params) do
      nil -> :ignore_one
      name -> {:ok, key(name), tail}
    end
  end

  defp csi_final(?~, params, tail) do
    case modified_key(params) do
      nil ->
        case params |> String.split(";", parts: 2) |> List.first() do
          n when n in ["1", "7"] -> {:ok, key(:home), tail}
          n when n in ["4", "8"] -> {:ok, key(:end), tail}
          "3" -> {:ok, key(:delete), tail}
          "5" -> {:ok, key(:page_up), tail}
          "6" -> {:ok, key(:page_down), tail}
          _other -> :ignore_one
        end

      name ->
        {:ok, key(name), tail}
    end
  end

  defp modified_arrow(final, params) do
    with {:ok, direction} when direction in [:left, :right] <- arrow(final),
         [_, modifier] <- params |> String.split(";") |> Enum.map(&parse_int/1) do
      flags = modifier_flags(modifier)

      if flags.alt or flags.ctrl or flags.super do
        if direction == :left, do: :alt_b, else: :alt_f
      end
    else
      _other -> nil
    end
  end

  # Kitty CSI-u: ESC [ <keycode> ; <modifier> u
  # xterm modifyOtherKeys: ESC [ 27 ; <modifier> ; <keycode> ~
  defp modified_key(params) do
    parts =
      params
      |> String.split(";")
      |> Enum.map(&parse_int/1)

    case parts do
      [keycode, modifier] -> modified_key(keycode, modifier)
      [27, modifier, keycode] -> modified_key(keycode, modifier)
      _other -> nil
    end
  end

  defp modified_key(127, modifier) do
    flags = modifier_flags(modifier)

    cond do
      flags.super -> :cmd_backspace
      flags.ctrl -> :ctrl_backspace
      true -> nil
    end
  end

  defp modified_key(keycode, modifier) when keycode in [?+, ?=, ?-] do
    flags = modifier_flags(modifier)

    cond do
      flags.super and keycode in [?+, ?=] -> :cmd_plus
      flags.super and keycode == ?- -> :cmd_minus
      true -> nil
    end
  end

  defp modified_key(_keycode, _modifier), do: nil

  defp modifier_flags(modifier) when is_integer(modifier) do
    bits = max(modifier - 1, 0)

    %{
      shift: :erlang.band(bits, 1) != 0,
      alt: :erlang.band(bits, 2) != 0,
      ctrl: :erlang.band(bits, 4) != 0,
      super: :erlang.band(bits, 8) != 0
    }
  end

  defp modifier_flags(_modifier), do: %{shift: false, alt: false, ctrl: false, super: false}

  # SGR mouse: ESC [ < b ; x ; y (M|m). Wheel up = 64, wheel down = 65; other
  # button/move reports are consumed but not surfaced as input.
  defp sgr_mouse(<<d, rest::binary>>, acc) when d in ?0..?9 or d == ?;,
    do: sgr_mouse(rest, [d | acc])

  defp sgr_mouse(<<t, rest::binary>>, acc) when t in [?M, ?m] do
    {:ok, mouse_event(acc |> Enum.reverse() |> IO.iodata_to_binary()), rest}
  end

  defp sgr_mouse(<<>>, _acc), do: :incomplete
  defp sgr_mouse(_other, _acc), do: :ignore_one

  defp mouse_event(spec) do
    case String.split(spec, ";") do
      [b, x, y] -> wheel(parse_int(b), parse_int(x), parse_int(y))
      _other -> mouse(:other, nil, nil)
    end
  end

  defp wheel(64, x, y), do: mouse(:wheel_up, x, y)
  defp wheel(65, x, y), do: mouse(:wheel_down, x, y)
  defp wheel(_button, _x, _y), do: mouse(:other, nil, nil)

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp mouse(name, x, y), do: %{type: :mouse, key: name, x: x, y: y}

  defp arrow(?A), do: {:ok, :up}
  defp arrow(?B), do: {:ok, :down}
  defp arrow(?C), do: {:ok, :right}
  defp arrow(?D), do: {:ok, :left}
  defp arrow(_other), do: :error

  defp utf8_take(<<lead, _::binary>> = buffer) do
    expected = utf8_length(lead)

    cond do
      expected == :invalid -> :invalid
      byte_size(buffer) < expected -> :incomplete
      true -> validate_utf8(binary_part(buffer, 0, expected), buffer, expected)
    end
  end

  defp validate_utf8(candidate, buffer, expected) do
    case candidate do
      <<grapheme::utf8>> ->
        {:ok, <<grapheme::utf8>>, binary_part(buffer, expected, byte_size(buffer) - expected)}

      _invalid ->
        :invalid
    end
  end

  defp utf8_length(lead) when lead >= 0xF0 and lead <= 0xF4, do: 4
  defp utf8_length(lead) when lead >= 0xE0 and lead < 0xF0, do: 3
  defp utf8_length(lead) when lead >= 0xC2 and lead < 0xE0, do: 2
  defp utf8_length(_lead), do: :invalid

  defp key(name), do: %{type: :key, key: name, char: nil}
  defp char(grapheme), do: %{type: :key, key: :char, char: grapheme}
end
