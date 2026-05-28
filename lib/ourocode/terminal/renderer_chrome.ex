defmodule Ourocode.Terminal.RendererChrome do
  @moduledoc """
  Header, composer, and status bar drawing for the terminal renderer.
  """

  alias Ourocode.Terminal.{FrameSections, PromptActivityIndicator, Screen}

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
    |> Screen.put_text(@left, 2, "plan, delegate, and verify from one terminal", :dim)
  end

  @spec draw_composer(map(), pos_integer(), integer(), String.t(), atom(), map()) :: map()
  def draw_composer(screen, width, rule_row, prompt_buffer, mode, opts) do
    placeholder =
      cond do
        Map.get(opts, :interview_paused, false) ->
          "/answer <text> resumes; type normally to discuss"

        Map.get(opts, :interview_decision, false) ->
          ""

        Map.get(opts, :wonder_focus, false) ->
          ""

        mode == :palette ->
          "type to filter commands"

        width < 64 ->
          "Type / or ooo; Enter runs"

        true ->
          "Message ourocode, / for commands, ooo starts structured work"
      end

    live_activity? = Map.get(opts, :live_turn_activity, []) != []
    prompt_busy? = live_activity? or Map.get(opts, :streaming, false)

    {body_text, body_style} =
      cond do
        prompt_buffer != "" ->
          {prompt_buffer, :text}

        prompt_busy? ->
          {"Queue a follow-up; Esc interrupts", :placeholder}

        true ->
          {placeholder, :placeholder}
      end

    {marker, body_x} =
      if prompt_busy? do
        {prompt_activity_marker(Map.get(opts, :tick, 0)), @body + 4}
      else
        {">", @body}
      end

    screen =
      screen
      |> Screen.put_text(@left, rule_row, "", :border)
      |> Screen.put_text(@left, rule_row + 1, marker, :accent)

    put_composer_text(screen, body_x, rule_row + 1, body_text, body_style, width - body_x - @left)
  end

  @spec draw_status_bar(map(), pos_integer(), integer(), map(), map(), atom(), map()) :: map()
  def draw_status_bar(screen, width, row, kv, sections, mode, opts) do
    sessions = FrameSections.session_count(sections)
    status = Map.get(kv, "status", "")

    queued = Map.get(kv, "queued", "0")
    hooks = Map.get(kv, "hooks", "idle")

    runtime = runtime_label(Map.get(kv, "runtime", "?"), status)

    left =
      [runtime]
      |> maybe(sessions > 0, "#{sessions} active")
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
        Map.get(opts, :workspace_active, false) -> workspace_hints(width)
        mode == :palette -> "Up/Dn  Enter run  Esc"
        true -> responsive_hints(width, sections)
      end

    hint_col = max(width - String.length(hints) - @left, @left)
    hint_style = if Map.get(opts, :notifications, []) != [], do: :accent, else: :muted

    screen
    |> Screen.put_text(@left, row, fit_left(left, hint_col - @left - 2), :dim)
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

  defp runtime_label(runtime, status) when runtime in ["?", "unknown", nil] do
    if status in ["healthy", "ready"], do: "ready", else: "main"
  end

  defp runtime_label(runtime, _status), do: runtime

  defp activity_dot(kv, opts) do
    if Map.get(opts, :streaming) do
      frame = Enum.at(@pulse, rem(Map.get(opts, :tick, 0), length(@pulse)))
      {frame, :accent}
    else
      health_indicator(kv)
    end
  end

  defp prompt_activity_marker(tick) do
    PromptActivityIndicator.frame(tick)
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

  defp responsive_hints(width, _sections) when width < 52, do: "/  ooo  ^C"
  defp responsive_hints(width, _sections) when width < 76, do: "/ commands  ooo work  ^C"

  defp responsive_hints(_width, sections) when sections == %{},
    do: "/ commands  ooo work  ^C"

  defp responsive_hints(_width, _sections), do: "/ commands  ooo work  Up/^P history  ^C"

  defp workspace_hints(width) when width < 52, do: "workspace  Up/Dn  Enter"
  defp workspace_hints(width) when width < 76, do: "workspace  Up/Dn rows  Enter action"

  defp workspace_hints(_width),
    do: "workspace focus  Up/Dn rows  Enter row action  type to compose"

  defp fit_left(_text, max_width) when max_width < 8, do: ""

  defp fit_left(text, max_width) do
    if Screen.text_width(text) <= max_width do
      text
    else
      text
      |> String.split(~r/\s{2,}/, trim: true)
      |> Enum.reduce_while("", fn part, acc ->
        next = if acc == "", do: part, else: acc <> "   " <> part

        if Screen.text_width(next) <= max_width do
          {:cont, next}
        else
          {:halt, acc}
        end
      end)
    end
  end
end
