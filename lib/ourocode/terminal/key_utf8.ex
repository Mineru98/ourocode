defmodule Ourocode.Terminal.KeyUtf8 do
  @moduledoc """
  UTF-8 byte-sequence extraction for raw terminal input.

  Raw terminal reads can split a multi-byte character across chunks. This
  module recognizes whether the leading bytes contain a complete UTF-8
  grapheme, need more bytes, or are invalid input that the caller should drop.
  """

  @type take_result :: {:ok, String.t(), binary()} | :incomplete | :invalid

  @spec take(binary()) :: take_result()
  def take(<<lead, _::binary>> = buffer) do
    expected = byte_length(lead)

    cond do
      expected == :invalid -> :invalid
      byte_size(buffer) < expected -> :incomplete
      true -> validate(binary_part(buffer, 0, expected), buffer, expected)
    end
  end

  def take(<<>>), do: :incomplete

  defp validate(candidate, buffer, expected) do
    case candidate do
      <<grapheme::utf8>> ->
        {:ok, <<grapheme::utf8>>, binary_part(buffer, expected, byte_size(buffer) - expected)}

      _invalid ->
        :invalid
    end
  end

  defp byte_length(lead) when lead >= 0xF0 and lead <= 0xF4, do: 4
  defp byte_length(lead) when lead >= 0xE0 and lead < 0xF0, do: 3
  defp byte_length(lead) when lead >= 0xC2 and lead < 0xE0, do: 2
  defp byte_length(_lead), do: :invalid
end
