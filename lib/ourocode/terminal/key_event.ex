defmodule Ourocode.Terminal.KeyEvent do
  @moduledoc """
  Constructors for normalized terminal input events.
  """

  @spec key(atom()) :: map()
  def key(name), do: %{type: :key, key: name, char: nil}

  @spec char(String.t()) :: map()
  def char(grapheme) when is_binary(grapheme), do: %{type: :key, key: :char, char: grapheme}

  @spec paste(String.t()) :: map()
  def paste(text) when is_binary(text), do: %{type: :key, key: :paste, char: text}

  @spec mouse(atom(), integer() | nil, integer() | nil) :: map()
  def mouse(name, x, y), do: %{type: :mouse, key: name, x: x, y: y}
end
