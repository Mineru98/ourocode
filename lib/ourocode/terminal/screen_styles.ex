defmodule Ourocode.Terminal.ScreenStyles do
  @moduledoc """
  ANSI SGR palette for terminal screen cells.
  """

  @reset "\e[0m"

  # 24-bit truecolor design system. The Rust tty helper writes frames verbatim
  # to the host terminal (no SGR rewriting, no capability gating), so colour
  # depth is the terminal's, not ours to fear. Identity is one warm gold accent
  # used rarely (wordmark, caret, selection, live pulse, interview rail) over a
  # cool neutral ramp; body text stays the terminal's own foreground so it
  # adapts to the user's theme. Restraint, not saturation, carries the look.
  # Every entry leads with `0;` so each styled run is fully self-contained:
  # weight and colour reset before they are re-set, so a bold run never bleeds
  # into the dim run beside it on the same row.
  @styles %{
    brand: "\e[0;1;38;2;227;179;65m",
    accent: "\e[0;38;2;227;179;65m",
    strong: "\e[0;1;38;2;245;245;247m",
    label: "\e[0;1;38;2;142;142;150m",
    dim: "\e[0;38;2;141;141;149m",
    muted: "\e[0;38;2;101;101;110m",
    border: "\e[0;38;2;58;58;64m",
    title: "\e[0;1;38;2;227;179;65m",
    ok: "\e[0;38;2;63;185;80m",
    warn: "\e[0;38;2;210;153;34m",
    err: "\e[0;38;2;248;81;73m",
    placeholder: "\e[0;38;2;84;84;93m",
    text: "\e[0m",
    # Panel surface: a self-contained shaded sidebar that owns both its
    # background and foreground so contrast is guaranteed regardless of the
    # host terminal theme (the global palette stays adaptive). A subtle light
    # fill separates the right pane without any rule or box character.
    p_fill: "\e[0;48;2;233;233;236m",
    p_title: "\e[0;1;48;2;233;233;236;38;2;31;31;36m",
    p_accent: "\e[0;48;2;233;233;236;38;2;150;108;22m",
    p_dim: "\e[0;48;2;233;233;236;38;2;77;77;85m",
    p_muted: "\e[0;48;2;233;233;236;38;2;135;135;143m",
    p_err: "\e[0;48;2;233;233;236;38;2;179;38;30m"
  }

  @type style ::
          :brand
          | :accent
          | :strong
          | :label
          | :dim
          | :muted
          | :border
          | :title
          | :ok
          | :warn
          | :err
          | :placeholder
          | :text
          | :p_fill
          | :p_title
          | :p_accent
          | :p_dim
          | :p_muted
          | :p_err

  @spec reset() :: String.t()
  def reset, do: @reset

  @spec sgr(style()) :: String.t()
  def sgr(style), do: Map.fetch!(@styles, style)

  @spec styled?(style() | nil) :: boolean()
  def styled?(style), do: style not in [nil, :text]
end
