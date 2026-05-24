defmodule Ourocode.Terminal.RendererChrome do
  @moduledoc """
  Header, composer, and status bar drawing for the terminal renderer.
  """

  alias Ourocode.Terminal.{FrameSections, Screen}

  @left 2
  @body 4
  @pulse [".", "o", "O", "o"]

  @spec draw_header(map(), pos_integer(), map(), map()) :: map()
  def draw_header(screen, width, kv, opts) do
    {dot, dot_style} = activity_dot(kv, opts)

    status_word =
      if Map.get(opts, :streaming), do: "thinking", else: Map.get(kv, "status", "starting")

    {auth_text, auth_style} = Map.get(opts, :auth, {"no model  -  /model", :dim})
    auth_col = max(width - String.length(auth_text) - @left, @left)
    status_col = max(auth_col - String.length(status_word) - 4, @left + 20)

    screen
    |> Screen.put_text(@left, 1, "ourocode", :brand)
    |> Screen.put_text(@left + 9, 1, "agent", :dim)
    |> Screen.put_text(status_col, 1, dot, dot_style)
    |> Screen.put_text(status_col + 2, 1, status_word, :dim)
    |> Screen.put_text(auth_col, 1, auth_text, auth_style)
    |> Screen.put_text(@left, 2, "terminal-native interactive baseline", :dim)
  end

  @spec draw_composer(map(), pos_integer(), integer(), String.t(), atom(), map()) :: map()
  def draw_composer(screen, width, rule_row, prompt_buffer, mode, opts) do
    rule = String.duplicate("-", max(width - 2 * @left, 0))

    placeholder =
      cond do
        Map.get(opts, :interview_paused, false) ->
          "/answer <answer> submits to interview, or type normally to discuss with main session"

        Map.get(opts, :wonder_focus, false) ->
          "Free answer for this interview checkpoint, or Esc to talk to main session"

        mode == :palette ->
          "type to filter commands"

        true ->
          "Message ourocode, or  /  for commands"
      end

    {body_text, body_style} =
      if prompt_buffer == "",
        do: {placeholder, :placeholder},
        else: {prompt_buffer, :text}

    screen =
      screen
      |> Screen.put_text(@left, rule_row, rule, :border)
      |> Screen.put_text(@left, rule_row + 1, ">", :accent)

    put_composer_text(screen, @body, rule_row + 1, body_text, body_style, width - @body - @left)
  end

  @spec draw_status_bar(map(), pos_integer(), integer(), map(), map(), atom(), map()) :: map()
  def draw_status_bar(screen, width, row, kv, sections, mode, opts) do
    transports =
      case Map.get(kv, "transports", "none") do
        "none" -> "offline"
        list -> list |> String.replace("streamable_http", "http") |> String.replace(",", " ")
      end

    queued = Map.get(kv, "queued", "0")
    hooks = Map.get(kv, "hooks", "idle")
    sessions = FrameSections.session_count(sections)
    plugins = FrameSections.plugin_count(sections)

    left =
      [Map.get(kv, "runtime", "?"), transports]
      |> maybe(sessions > 0, "#{sessions} sessions")
      |> maybe(plugins > 0, "#{plugins} plugins")
      |> maybe(queued != "0", "q#{queued}")
      |> maybe(hooks != "idle", "hooks #{hooks}")
      |> Enum.join("   ")

    notification =
      case Map.get(opts, :notifications, []) do
        [note | _rest] -> note
        _none -> nil
      end

    hints =
      cond do
        is_binary(notification) -> notification
        mode == :palette -> "Up/Dn  Enter run  Esc"
        true -> "/  commands     Up/^P history     ^Y yank     ^C  exit"
      end

    hint_col = max(width - String.length(hints) - @left, @left)
    hint_style = if Map.get(opts, :notifications, []) != [], do: :accent, else: :muted

    screen
    |> Screen.put_text(@left, row, clip(left, hint_col - @left - 2), :dim)
    |> Screen.put_text(hint_col, row, hints, hint_style)
  end

  defp put_composer_text(screen, x, y, text, :text, width) do
    clipped = clip(text, width)

    if String.starts_with?(String.trim_leading(clipped), "ooo") do
      leading = byte_size(clipped) - byte_size(String.trim_leading(clipped))
      prefix = binary_part(clipped, 0, leading)
      rest = binary_part(clipped, leading, byte_size(clipped) - leading)

      screen = Screen.put_text(screen, x, y, prefix, :text)
      token_w = Screen.text_width(prefix)

      screen
      |> Screen.put_text(x + token_w, y, "ooo", :brand)
      |> Screen.put_text(x + token_w + 3, y, String.replace_prefix(rest, "ooo", ""), :text)
    else
      Screen.put_text(screen, x, y, clipped, :text)
    end
  end

  defp put_composer_text(screen, x, y, text, style, width) do
    Screen.put_text(screen, x, y, clip(text, width), style)
  end

  defp activity_dot(kv, opts) do
    if Map.get(opts, :streaming) do
      frame = Enum.at(@pulse, rem(Map.get(opts, :tick, 0), length(@pulse)))
      {frame, :accent}
    else
      health_indicator(kv)
    end
  end

  defp health_indicator(kv) do
    case Map.get(kv, "status", "starting") do
      "healthy" -> {"*", :ok}
      "ready" -> {"*", :ok}
      "starting" -> {"*", :warn}
      _other -> {"*", :err}
    end
  end

  defp maybe(list, false, _item), do: list
  defp maybe(list, true, item), do: list ++ [item]

  defp clip(text, max_width), do: Screen.truncate(text, max_width)
end
