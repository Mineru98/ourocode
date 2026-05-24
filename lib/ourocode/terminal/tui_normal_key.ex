defmodule Ourocode.Terminal.TuiNormalKey do
  @moduledoc """
  Pure key classification for normal-mode TUI events.
  """

  @editing_keys MapSet.new([
                  :delete,
                  :left,
                  :right,
                  :home,
                  :end,
                  :ctrl_a,
                  :ctrl_b,
                  :ctrl_e,
                  :ctrl_f,
                  :ctrl_k,
                  :ctrl_u,
                  :ctrl_w,
                  :ctrl_y,
                  :alt_b,
                  :alt_d,
                  :alt_f,
                  :alt_y,
                  :cmd_backspace,
                  :ctrl_backspace
                ])

  @spec editing?(map()) :: boolean()
  def editing?(%{key: key}), do: MapSet.member?(@editing_keys, key)
  def editing?(_event), do: false

  @spec scroll_delta(map()) :: integer() | nil
  def scroll_delta(%{type: :mouse, key: :wheel_up}), do: 3
  def scroll_delta(%{type: :mouse, key: :wheel_down}), do: -3
  def scroll_delta(%{key: :page_up}), do: 8
  def scroll_delta(%{key: :page_down}), do: -8
  def scroll_delta(_event), do: nil
end
