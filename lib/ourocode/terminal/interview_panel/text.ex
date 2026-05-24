defmodule Ourocode.Terminal.InterviewPanel.Text do
  @moduledoc """
  Text normalization helpers for interview panel rendering.
  """

  @spec md_text(term()) :: String.t()
  def md_text(text) do
    text
    |> to_string()
    |> String.replace(~r/(\*\*|__)(.*?)\1/s, "\\2")
    |> String.replace(~r/(\*|_)(.*?)\1/s, "\\2")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/^\s{0,3}\#{1,6}\s+/m, "")
    |> String.replace(~r/\[([^\]]+)\]\([^)]+\)/, "\\1")
    |> strip_unstable_glyphs()
    |> String.trim()
  end

  @spec flatten_line(term()) :: String.t()
  def flatten_line(text) do
    text
    |> md_text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @spec plain_line(term()) :: String.t()
  def plain_line(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp strip_unstable_glyphs(text) do
    text
    |> String.replace(~r/[\x{FFFD}\x{FE0E}\x{FE0F}\x{200D}]/u, "")
    |> String.replace(~r/[\x{1F000}-\x{1FAFF}]/u, "")
    |> String.replace(~r/\s+/, " ")
  end
end
