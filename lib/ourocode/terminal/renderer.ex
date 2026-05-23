defmodule Ourocode.Terminal.Renderer do
  @moduledoc false

  alias Ourocode.Model
  alias Ourocode.Runtime.CapabilityGraph
  alias Ourocode.Terminal.{InterviewPanel, Palette, Screen, Suggestions}

  @min_width 40
  @min_height 16

  @left 2
  @body 4
  @pulse [".", "o", "O", "o"]

  def compose(columns, rows, sections, activity, prompt_buffer, opts) do
    width = max(columns, @min_width)
    height = max(rows, @min_height)
    kv = status_fields(sections)
    mode = Map.get(opts, :mode, :normal)
    login = Map.get(opts, :login)
    palette = Map.get(opts, :palette)
    model_overlay = Map.get(opts, :model)
    interview_block = Map.get(opts, :interview_block)
    wonder_focus = Map.get(opts, :wonder_focus, false)
    reasoning = Map.get(opts, :interview_reasoning, [])
    mcp_activity = Map.get(opts, :mcp_activity, [])
    activity = maybe_focus_paused_interview_activity(activity, opts)
    interview_present? = match?({_marker, _lines, _hint}, interview_block)
    interview_owns_left? = interview_present? and not Map.get(opts, :interview_paused, false)
    body_activity = if interview_owns_left?, do: [], else: activity
    palette = maybe_add_paused_answer_palette(palette, prompt_buffer, opts)
    file_mentions = Map.get(opts, :file_mentions, [])
    file_mention_index = Palette.clamp(Map.get(opts, :pidx, 0), length(file_mentions))

    resource_mentions =
      Suggestions.resource_mention_suggestions(prompt_buffer, mode, wonder_focus, opts)

    resource_mention_index = Palette.clamp(Map.get(opts, :pidx, 0), length(resource_mentions))

    ooo_suggestions =
      Suggestions.ooo_suggestions(prompt_buffer, mode, wonder_focus, Map.get(opts, :ooo_commands))

    ooo_index = Palette.clamp(Map.get(opts, :pidx, 0), length(ooo_suggestions))

    composer_rule = height - 3
    transcript_top = 4
    transcript_bottom = composer_rule - 2

    screen =
      Screen.new(width, height)
      |> draw_header(width, kv, opts)

    scroll = Map.get(opts, :scroll, 0)
    split? = mcp_active?(sections) or reasoning != [] or mcp_activity != []

    # A live picker is an intentional checkpoint: mute the rest of the body
    # and let the decision UI own the available space so it cannot be missed.
    screen =
      if wonder_focus and interview_present? do
        draw_wonder_focus(
          screen,
          width,
          transcript_top,
          transcript_bottom,
          interview_block,
          prompt_buffer
        )
      else
        screen
      end

    # A pending interview pins a prominent block at the top of the left column
    # (not a modal). In split mode it consumes only the left column; the right
    # telemetry panel keeps its full height so it does not jump when questions
    # arrive.
    {screen, body_top} =
      case {wonder_focus, interview_block} do
        {true, {_marker, _lines, _hint}} ->
          {screen, transcript_top}

        {_focus, nil} ->
          {screen, transcript_top}

        {_focus, {marker, lines, hint}} ->
          left_w = split_left_w(width)
          block_w = if reasoning == [] and not mcp_active?(sections), do: width, else: left_w
          max_rows = max(transcript_bottom - transcript_top - 1, 1)

          {screen, used} =
            draw_interview_block(screen, transcript_top, block_w, marker, lines, hint, max_rows)

          {screen, transcript_top + used + 1}
      end

    screen =
      cond do
        wonder_focus and interview_present? ->
          screen

        login ->
          draw_login_card(screen, width, transcript_top, transcript_bottom, login)

        palette || model_overlay ->
          draw_transcript(
            screen,
            width,
            body_top,
            transcript_bottom,
            body_activity,
            false,
            scroll
          )

        split? ->
          draw_runtime_split(
            screen,
            width,
            if(interview_owns_left?, do: transcript_bottom + 1, else: body_top),
            transcript_top,
            transcript_bottom,
            body_activity,
            sections,
            scroll,
            reasoning,
            mcp_activity
          )

        interview_owns_left? ->
          screen

        true ->
          draw_transcript(screen, width, body_top, transcript_bottom, body_activity, true, scroll)
      end

    screen =
      cond do
        palette ->
          draw_palette(screen, width, transcript_bottom, palette)

        model_overlay ->
          draw_model_overlay(screen, width, transcript_bottom, model_overlay)

        resource_mentions != [] ->
          draw_resource_mentions(
            screen,
            width,
            transcript_bottom,
            resource_mentions,
            resource_mention_index
          )

        file_mentions != [] ->
          draw_file_mentions(screen, width, transcript_bottom, file_mentions, file_mention_index)

        ooo_suggestions != [] ->
          draw_ooo_suggestions(screen, width, transcript_bottom, ooo_suggestions, ooo_index)

        Map.get(opts, :key_help, false) ->
          draw_key_help(screen, width, transcript_bottom, mode, opts)

        true ->
          screen
      end

    screen
    |> draw_composer(width, composer_rule, prompt_buffer, mode, opts)
    |> draw_status_bar(width, height - 1, kv, sections, mode, opts)
  end

  defp maybe_focus_paused_interview_activity(activity, %{interview_paused: true}) do
    paused_interview_discussion_activity(activity)
  end

  defp maybe_focus_paused_interview_activity(activity, _opts), do: activity

  defp paused_interview_discussion_activity(activity) when activity in [nil, []], do: []

  defp paused_interview_discussion_activity(activity) do
    activity
    |> Enum.reduce({[], nil}, fn line, {kept, role} ->
      trimmed = String.trim(line)

      cond do
        paused_interview_noise?(trimmed) ->
          {kept, nil}

        String.starts_with?(trimmed, "you> ") or String.starts_with?(trimmed, "> ") ->
          {[line | kept], :user}

        String.starts_with?(trimmed, "ourocode> ") ->
          {[line | kept], :assistant}

        role in [:user, :assistant] and trimmed != "" and not system_line?(trimmed) ->
          {[line | kept], role}

        true ->
          {kept, nil}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp paused_interview_noise?(trimmed) when is_binary(trimmed) do
    downcased = String.downcase(trimmed)

    trimmed in ["", "empty", "-- empty"] or
      String.starts_with?(trimmed, "-- ") or
      String.contains?(downcased, [
        "[workflow-starting]",
        "queued task ",
        "interview paused",
        "workflow",
        "dispatching_input"
      ])
  end

  defp paused_interview_noise?(_trimmed), do: false

  defp maybe_add_paused_answer_palette(%{entries: entries} = palette, prompt_buffer, opts) do
    if Map.get(opts, :interview_paused, false) do
      answer_entries =
        if paused_answer_query?(prompt_buffer),
          do: [paused_answer_entry()],
          else: Palette.filter([paused_answer_entry()], prompt_buffer)

      entries = answer_entries ++ Enum.reject(entries, &(&1.slash == "/answer"))
      index = Palette.clamp(Map.get(opts, :pidx, Map.get(palette, :index, 0)), length(entries))
      %{palette | entries: entries, index: index}
    else
      palette
    end
  end

  defp maybe_add_paused_answer_palette(palette, _prompt_buffer, _opts), do: palette

  defp paused_answer_query?(prompt_buffer) when is_binary(prompt_buffer) do
    prompt_buffer
    |> String.trim_leading()
    |> String.downcase()
    |> then(&(&1 == "/answer" or String.starts_with?(&1, "/answer ")))
  end

  defp paused_answer_query?(_prompt_buffer), do: false

  defp paused_answer_entry do
    %{
      slash: "/answer",
      name: "answer",
      summary: "Use while paused: /answer <answer> submits to the interview.",
      category: :interaction,
      source: :runtime,
      availability: :ready,
      aliases: [],
      args: [%{name: "answer", required?: true, description: "Interview answer text"}]
    }
  end

  # Accent appears in exactly four places (wordmark, caret, selected palette
  # row, healthy/streaming dot). Everything else is neutral grey so the accent
  # stays rare and meaningful.
  defp draw_header(screen, width, kv, opts) do
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

  defp activity_dot(kv, opts) do
    if Map.get(opts, :streaming) do
      frame = Enum.at(@pulse, rem(Map.get(opts, :tick, 0), length(@pulse)))
      {frame, :accent}
    else
      health_indicator(kv)
    end
  end

  # R1: turns render as scannable blocks - a dim role label, a coloured left
  # rail, and an indented body - instead of a flat log. This is the structure
  # a conversation needs and the one thing that makes it feel designed.
  defp draw_transcript(
         screen,
         width,
         top,
         bottom,
         activity,
         show_empty_hint,
         scroll,
         clip_override \\ nil
       ) do
    region = max(bottom - top + 1, 1)
    render_rows = transcript_render_rows(activity)

    cond do
      render_rows == [] and not show_empty_hint ->
        screen

      render_rows == [] ->
        mid = top + div(region, 2)

        screen
        |> center(mid - 1, width, "ourocode", :brand)
        |> center(mid + 1, width, "Sign in with  /login,  then ask anything", :dim)
        |> center(mid + 2, width, "or type  /  to browse commands", :muted)

      true ->
        # `scroll` rows back from the tail; clamped so it can never run past
        # the buffered history (full scroll-back, no 8-line truncation).
        total = length(render_rows)
        offset = min(max(scroll, 0), max(total - region, 0))
        slice_end = total - offset
        slice_start = max(slice_end - region, 0)
        visible = Enum.slice(render_rows, slice_start, slice_end - slice_start)
        start = bottom - length(visible) + 1

        visible
        |> Enum.with_index()
        |> Enum.reduce(screen, fn {row, i}, acc ->
          y = start + i

          acc =
            case row.rail do
              nil -> acc
              ch -> Screen.put_text(acc, @left, y, ch, row.rail_style)
            end

          clip_w = clip_override || width - @body - @left
          Screen.put_text(acc, @body, y, clip(row.text, clip_w), row.text_style)
        end)
    end
  end

  defp transcript_render_rows(activity) when activity in [nil, []], do: []

  defp transcript_render_rows(activity) do
    activity
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reduce({[], nil}, &fold_transcript_line/2)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == :sep))
    |> Enum.map(&render_row/1)
  end

  defp fold_transcript_line(line, {rows, role}) do
    cond do
      # A leaked SSoT block (e.g. parent-pane workflow feedback) borrows the
      # +--/| frame syntax meant for the status channel, not the transcript.
      # Swallow the frame; surface only its inner content as clean system
      # notes so no box-art fragment ever reaches the conversation.
      String.starts_with?(line, "+-- ") ->
        {rows, :ssot}

      role == :ssot and line == "+--" ->
        {rows, nil}

      role == :ssot ->
        case strip_prefix(line, "| ") do
          nil -> {rows, :ssot}
          inner -> {[{:system, humanize(inner)}, :sep | rows], :ssot}
        end

      rest = strip_prefix(line, "you> ") ->
        push_block(rows, :user, "YOU", rest)

      rest = strip_prefix(line, "ourocode> ") ->
        push_block(rows, :assistant, "OUROCODE", rest)

      rest = strip_prefix(line, "> ") ->
        push_block(rows, :user, "YOU", rest)

      system_line?(line) ->
        {[{:system, line}, :sep | rows], nil}

      line == "" ->
        {rows, role}

      role in [:user, :assistant] ->
        {[{{:body, role}, line} | rows], role}

      true ->
        {[{:system, line}, :sep | rows], nil}
    end
  end

  defp push_block(rows, role, label, first) do
    rows = [{{:body, role}, first}, {{:label, role}, label}, :sep | rows]
    {rows, role}
  end

  defp strip_prefix(line, prefix) do
    if String.starts_with?(line, prefix),
      do: String.replace_prefix(line, prefix, ""),
      else: nil
  end

  defp system_line?(line) do
    String.starts_with?(line, [
      "queued ",
      "Signed ",
      "Sign in",
      "Login",
      "Not connected",
      "No model",
      "Model error",
      "Connect ChatGPT",
      "model:"
    ]) or String.contains?(line, ["error", "failed"])
  end

  defp render_row(:sep), do: %{rail: nil, rail_style: :text, text: "", text_style: :text}

  defp render_row({{:label, _role}, text}),
    do: %{rail: nil, rail_style: :text, text: text, text_style: :label}

  defp render_row({{:body, :user}, text}),
    do: %{rail: "|", rail_style: :accent, text: text, text_style: :strong}

  defp render_row({{:body, :assistant}, text}),
    do: %{rail: "|", rail_style: :dim, text: text, text_style: :text}

  # System notes (model switches, sign-in status, warnings) are deliberately
  # set apart from conversation turns: no role label, no rail, dimmer, and a
  # `--` lead so the eye never confuses them with what the model said.
  defp render_row({:system, text}),
    do: %{rail: nil, rail_style: :text, text: "-- " <> humanize(text), text_style: :muted}

  defp draw_wonder_focus(screen, width, top, bottom, {marker, lines, hint}, prompt_buffer) do
    panel_x = @left
    panel_w = max(width - 2 * @left, 1)
    panel_h = max(bottom - top + 1, 1)
    inner_x = panel_x + 2
    inner_w = max(panel_w - 4, 1)
    max_content = max(panel_h - 5, 1)

    rows =
      lines
      |> Enum.flat_map(&wrap_focus_line(&1, inner_w))
      |> Enum.take(max_content)

    input =
      case String.trim(prompt_buffer) do
        "" -> "Free answer: type here, then Enter"
        text -> "Free answer: " <> text
      end

    hint = "j/k or Up/Dn select   h/l or Left/Right question   Esc main session   " <> hint

    screen =
      screen
      |> Screen.fill_rect(0, top, width, panel_h, :p_fill)
      |> Screen.put_text(inner_x, top + 1, clip(marker, inner_w), :p_title)

    screen =
      rows
      |> Enum.with_index(2)
      |> Enum.reduce(screen, fn {{text, style}, offset}, acc ->
        Screen.put_text(acc, inner_x, top + offset, clip(text, inner_w), style)
      end)

    hint_top = bottom - 2

    screen
    |> Screen.put_text(inner_x, hint_top, clip(input, inner_w), :p_accent)
    |> Screen.put_text(inner_x, hint_top + 1, clip(hint, inner_w), :p_muted)
  end

  defp wrap_focus_line(line, inner) when is_binary(line) do
    style =
      cond do
        String.starts_with?(line, ">> ") -> :p_accent
        String.starts_with?(line, "   [") -> :p_dim
        true -> :p_title
      end

    wrap_styled(line, style, inner)
  end

  # A focal, centred card for the login moment so the device code is the one
  # thing the eye lands on.
  defp draw_login_card(screen, width, top, bottom, login) do
    card_w = min(54, width - 2 * @left)
    card_h = 7
    x = div(width - card_w, 2)
    y = top + max(div(bottom - top + 1 - card_h, 2), 0)
    code = Map.get(login, :code, "------")
    url = Map.get(login, :url, "")

    screen
    |> Screen.box(x, y, card_w, card_h, "Connect ChatGPT", :accent)
    |> center(y + 2, width, url, :dim)
    |> center(y + 4, width, code, :brand)
    |> center(y + card_h, width, "waiting for approval - Ctrl-C to cancel", :muted)
  end

  @overlay_rows 8

  # Slides a window over the full list so the selection moves through every
  # item instead of wrapping inside the first eight rows (which made long
  # lists look frozen once you reached the visible end).
  defp window(items, _index) when items == [], do: {0, []}

  defp window(items, index) do
    total = length(items)
    idx = max(min(index, total - 1), 0)

    offset =
      cond do
        total <= @overlay_rows -> 0
        idx < @overlay_rows -> 0
        true -> min(idx - @overlay_rows + 1, total - @overlay_rows)
      end

    {offset, Enum.slice(items, offset, @overlay_rows) |> Enum.with_index(offset)}
  end

  defp draw_overlay(screen, width, anchor_bottom, title, items, index, row_fun) do
    {_offset, windowed} = window(items, index)
    box_w = width - 2 * @left
    inner = box_w - 2
    box_h = max(length(windowed), 1) + 2
    y = anchor_bottom - box_h + 1

    screen = Screen.box(screen, @left, y, box_w, box_h, title, :border)

    if windowed == [] do
      Screen.put_text(screen, @left + 1, y + 1, pad("  nothing here", inner), :dim)
    else
      windowed
      |> Enum.with_index()
      |> Enum.reduce(screen, fn {{item, abs_i}, row}, acc ->
        selected? = abs_i == index
        marker = if selected?, do: ">", else: " "
        line = " #{marker} #{row_fun.(item)}"
        style = if selected?, do: :accent, else: :dim
        Screen.put_text(acc, @left + 1, y + 1 + row, pad(line, inner), style)
      end)
    end
  end

  defp draw_palette(screen, width, anchor_bottom, %{entries: entries, index: index}) do
    screen =
      draw_overlay(
        screen,
        width,
        anchor_bottom,
        "commands  (#{length(entries)})",
        entries,
        index,
        fn e ->
          tag = if e.availability == :stub, do: "  (stub)", else: ""
          "#{String.pad_trailing(e.slash, 12)} #{e.summary}#{tag}"
        end
      )

    draw_palette_detail(screen, width, anchor_bottom, entries, index)
  end

  defp draw_palette_detail(screen, width, anchor_bottom, entries, index) do
    case Palette.selected(entries, index) do
      nil ->
        screen

      entry ->
        visible_rows = max(min(length(entries), @overlay_rows), 1)
        box_w = width - 2 * @left
        inner = box_w - 2
        rows = palette_detail_rows(entry, inner)
        y = anchor_bottom - visible_rows - 2 - length(rows)

        rows
        |> Enum.with_index()
        |> Enum.reduce(screen, fn {row, offset}, acc ->
          Screen.put_text(acc, @left + 1, y + offset, pad(row, inner), :muted)
        end)
    end
  end

  defp palette_detail_rows(entry, inner) do
    semantics =
      entry
      |> palette_capability_registry()
      |> CapabilityGraph.build()
      |> Map.fetch!(:capabilities)
      |> List.first()
      |> Map.fetch!(:semantics)

    aliases =
      case Map.get(entry, :aliases, []) do
        [] -> "none"
        values -> Enum.join(values, ", ")
      end

    args =
      entry
      |> Map.get(:args, [])
      |> Enum.map(fn arg ->
        suffix = if Map.get(arg, :required?), do: "!", else: "?"
        "#{Map.get(arg, :name, "arg")}#{suffix}"
      end)
      |> case do
        [] -> "none"
        values -> Enum.join(values, ", ")
      end

    [
      "selected #{entry.slash}  source=#{entry.source} trust=#{palette_trust_tier(entry)} category=#{entry.category} availability=#{entry.availability}",
      "capability #{semantics.scope}/#{semantics.mutation_class}/#{semantics.approval_class}  aliases=#{aliases}  args=#{args}"
    ]
    |> Enum.map(&Screen.truncate(&1, inner))
  end

  defp palette_trust_tier(%{source: :builtin}), do: "builtin"
  defp palette_trust_tier(%{source: :bundled_skill}), do: "bundled"
  defp palette_trust_tier(%{source: :local}), do: "local"
  defp palette_trust_tier(%{source: :plugin}), do: "plugin"
  defp palette_trust_tier(%{source: :mcp}), do: "mcp"
  defp palette_trust_tier(%{source: :dynamic_skill}), do: "dynamic"
  defp palette_trust_tier(_entry), do: "unknown"

  defp palette_capability_registry(entry) do
    %{
      ordered: [
        %{
          id: "#{entry.source}:#{entry.slash}",
          name: entry.name,
          slash: entry.slash,
          summary: entry.summary,
          source: entry.source,
          source_id: to_string(entry.source),
          category: entry.category,
          run_spec: %{}
        }
      ]
    }
  end

  defp draw_model_overlay(screen, width, anchor_bottom, %{models: models, index: index}) do
    draw_overlay(screen, width, anchor_bottom, "model", models, index, fn m ->
      status = if Model.ready?(m), do: "ready", else: "sign in required"
      "#{String.pad_trailing(m.label, 20)} #{status}"
    end)
  end

  defp draw_ooo_suggestions(screen, width, anchor_bottom, suggestions, index) do
    draw_overlay(screen, width, anchor_bottom, "ooo commands", suggestions, index, fn {command,
                                                                                       summary} ->
      "#{String.pad_trailing(command, 18)} #{summary}"
    end)
  end

  defp draw_file_mentions(screen, width, anchor_bottom, suggestions, index) do
    draw_overlay(screen, width, anchor_bottom, "@ files", suggestions, index, fn {path, label} ->
      "#{String.pad_trailing("@" <> path, 36)} #{label}"
    end)
  end

  defp draw_resource_mentions(screen, width, anchor_bottom, suggestions, index) do
    draw_overlay(screen, width, anchor_bottom, "@ mcp resources", suggestions, index, fn {uri,
                                                                                          label} ->
      "#{String.pad_trailing("@mcp:" <> uri, 40)} #{label}"
    end)
  end

  defp draw_key_help(screen, width, anchor_bottom, mode, opts) do
    rows =
      case {mode, Map.get(opts, :wonder_focus, false), Map.get(opts, :interview_paused, false)} do
        {_mode, true, _paused} ->
          [
            {"Up/Dn j/k", "move option"},
            {"Left/Right h/l", "move question"},
            {"Space", "toggle multi-select"},
            {"Enter", "submit or review"},
            {"Esc", "pause to main session"}
          ]

        {_mode, _focus, true} ->
          [
            {"/answer <text>", "submit to interview"},
            {"type normally", "discuss with main session"},
            {"Ctrl-G", "hide this help"}
          ]

        {:palette, _focus, _paused} ->
          [{"Up/Dn", "move"}, {"Enter", "run"}, {"Esc", "close"}, {"Ctrl-G", "hide help"}]

        _other ->
          [
            {"/", "commands"},
            {"@", "file mentions"},
            {"Up/Ctrl-P", "history"},
            {"Ctrl-A/E", "line start/end"},
            {"Ctrl-G", "hide help"}
          ]
      end

    draw_overlay(screen, width, anchor_bottom, "keys", rows, 0, fn {key, desc} ->
      "#{String.pad_trailing(key, 18)} #{desc}"
    end)
  end

  # Pads (or clips) to an exact width so an overlay fully covers whatever it
  # is drawn on top of, leaving no trailing residue.
  defp pad(text, width) do
    t = Screen.truncate(text, width)
    t <> String.duplicate(" ", max(width - Screen.text_width(t), 0))
  end

  defp clip(text, max_width), do: Screen.truncate(text, max_width)

  # R2: one quiet rule above a single caret line. No fax-style double rules.
  # The caret is the only accent in the lower region.
  defp draw_composer(screen, width, rule_row, prompt_buffer, mode, opts) do
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

  # Conditional density: only surface what carries signal. Zeroes and idle
  # states stay hidden so the line reads at a glance instead of as a wall.
  defp draw_status_bar(screen, width, row, kv, sections, mode, opts) do
    transports =
      case Map.get(kv, "transports", "none") do
        "none" -> "offline"
        list -> list |> String.replace("streamable_http", "http") |> String.replace(",", " ")
      end

    queued = Map.get(kv, "queued", "0")
    hooks = Map.get(kv, "hooks", "idle")
    sessions = count_sessions(sections)
    plugins = count_plugins(sections)

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

  defp maybe(list, false, _item), do: list
  defp maybe(list, true, item), do: list ++ [item]

  defp center(screen, y, width, text, style) do
    x = max(div(width - Screen.text_width(text), 2), 0)
    Screen.put_text(screen, x, y, text, style)
  end

  defp health_indicator(kv) do
    case Map.get(kv, "status", "starting") do
      "healthy" -> {"*", :ok}
      "ready" -> {"*", :ok}
      "starting" -> {"*", :warn}
      _other -> {"*", :err}
    end
  end

  # The split surfaces only while a runtime workflow is live; otherwise the
  # calm single transcript stays (and snapshot tests with empty panes too).
  defp mcp_active?(sections), do: count_sessions(sections) > 0

  # Left: scrollable conversation transcript. Right: MCP internals, parent
  # workflow on top, child session stream on the bottom. The split is what
  # makes streaming legible instead of a flat interleaved log.
  # Borderless sidebar style: one dim vertical rule is the only separator; the
  # right column is a bare titled telemetry sidebar whose sections size to
  # their content, not to the region. A too-narrow terminal collapses cleanly
  # back to a single full-width transcript.
  @mcp_right_min 28

  defp split_left_w(width), do: max(div(width * 3, 5), 32)

  defp draw_runtime_split(
         screen,
         width,
         left_top,
         right_top,
         bottom,
         activity,
         sections,
         scroll,
         reasoning,
         mcp_activity
       ) do
    left_w = split_left_w(width)
    right_w = width - left_w - 1

    if right_w < @mcp_right_min do
      draw_transcript_if_room(screen, width, left_top, bottom, activity, true, scroll)
    else
      draw_runtime_split_two_column(
        screen,
        left_w,
        right_w,
        left_top,
        right_top,
        bottom,
        activity,
        sections,
        scroll,
        reasoning,
        mcp_activity
      )
    end
  end

  defp draw_runtime_split_two_column(
         screen,
         left_w,
         right_w,
         left_top,
         right_top,
         bottom,
         activity,
         sections,
         scroll,
         reasoning,
         mcp_activity
       ) do
    right_x = left_w + 1
    panel_h = max(bottom - right_top + 1, 1)
    # The pane is a self-contained shaded surface with one row of breathing
    # room on every side; sections lay out inside that padded box.
    inner_x = right_x + 1
    inner_w = max(right_w - 2, 1)
    inner_top = right_top + 1
    region = max(bottom - inner_top + 1, 1)

    body = section_body(sections, "Parent/Child Sessions")
    parent_lines = runtime_pane_lines(body, "parent ")
    child_lines = runtime_pane_lines(body, "child ")
    reasoning_rows = wrap_sidebar_lines(reasoning, inner_w)
    parent_rows = wrap_sidebar_lines(parent_lines, inner_w)
    child_rows = wrap_sidebar_lines(child_lines, inner_w)
    activity_rows = wrap_sidebar_lines(mcp_activity, inner_w)

    activity_h =
      if activity_rows == [],
        do: 0,
        else: min(max(div(region, 3), 5), max(region - 5, 3))

    activity_gap = if activity_h == 0, do: 0, else: 1
    upper_region = max(region - activity_h - activity_gap, 2)

    # The interview reasoning section sits on top of the MCP telemetry when
    # the backend actually sends reasoning metadata. Raw Ouroboros logs are
    # rendered separately in the bottom activity stream.
    iv_h =
      if reasoning_rows == [],
        do: 0,
        else: min(length(reasoning_rows), max(div(upper_region, 3), 1)) + 2

    rest = max(upper_region - iv_h, 2)
    {parent_body_h, child_body_h} = mcp_section_heights(parent_rows, child_rows, rest)

    parent_top = inner_top + iv_h
    child_top = parent_top + 1 + parent_body_h + 1
    activity_top = inner_top + upper_region + activity_gap

    # The transcript stops a few columns short of the sidebar so a clean gutter
    # instead of a hard line divides the columns.
    transcript_clip_w = max(left_w - @body - @left, 1)

    screen
    |> draw_transcript_if_room(
      left_w,
      left_top,
      bottom,
      activity,
      true,
      scroll,
      transcript_clip_w
    )
    |> Screen.fill_rect(right_x, right_top, right_w, panel_h, :p_fill)
    |> maybe_draw_interview_section(inner_x, inner_top, inner_w, reasoning_rows, iv_h)
    |> draw_mcp_section(inner_x, parent_top, inner_w, "MCP parent", parent_rows, parent_body_h)
    |> draw_mcp_section(inner_x, child_top, inner_w, "child stream", child_rows, child_body_h)
    |> maybe_draw_activity_section(
      inner_x,
      activity_top,
      inner_w,
      activity_rows,
      activity_h,
      scroll
    )
  end

  defp draw_transcript_if_room(screen, width, top, bottom, activity, hint, scroll, clip \\ nil)

  defp draw_transcript_if_room(screen, _width, top, bottom, _activity, _hint, _scroll, _clip)
       when top > bottom,
       do: screen

  defp draw_transcript_if_room(screen, width, top, bottom, activity, hint, scroll, clip) do
    draw_transcript(screen, width, top, bottom, activity, hint, scroll, clip)
  end

  defp maybe_draw_interview_section(screen, _x, _y, _w, [], _h), do: screen

  defp maybe_draw_interview_section(screen, x, y, w, reasoning, iv_h) do
    draw_mcp_section(screen, x, y, w, "interview", reasoning, max(iv_h - 2, 1))
  end

  defp maybe_draw_activity_section(screen, _x, _y, _w, [], _h, _scroll), do: screen
  defp maybe_draw_activity_section(screen, _x, _y, _w, _lines, h, _scroll) when h < 2, do: screen

  defp maybe_draw_activity_section(screen, x, y, w, lines, h, scroll) do
    draw_mcp_activity_section(screen, x, y, w, "activity log", lines, h - 1, scroll)
  end

  defp wrap_sidebar_lines(lines, w) when is_list(lines) do
    width = max(w - 1, 1)

    lines
    |> Enum.flat_map(fn line ->
      line
      |> InterviewPanel.plain_line()
      |> wrap_text(width)
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # The pinned, prominent interview block uses an accent rail, marker,
  # emphasized content, and dim key hint. Long lines word-wrap to the
  # left-column width instead of truncating or bleeding into the right pane.
  # Returns `{screen, used_rows}` so the transcript flows below the *actual*
  # wrapped height.
  defp draw_interview_block(screen, top, w, marker, lines, hint, max_rows) do
    inner = max(w - @body - @left, 1)

    rows =
      lines
      |> Enum.flat_map(&wrap_logical_line(&1, inner))
      |> Enum.take(max_rows)

    screen =
      screen
      |> Screen.put_text(@left, top, "|", :accent)
      |> Screen.put_text(@body, top, clip(marker, inner), :brand)

    screen =
      rows
      |> Enum.with_index(1)
      |> Enum.reduce(screen, fn {{text, style}, i}, acc ->
        acc
        |> Screen.put_text(@left, top + i, "|", :accent)
        |> Screen.put_text(@body, top + i, clip(text, inner), style)
      end)

    hint_row = top + length(rows) + 1

    screen =
      screen
      |> Screen.put_text(@left, hint_row, "|", :accent)
      |> Screen.put_text(@body, hint_row, clip(hint, inner), :muted)

    {screen, 1 + length(rows) + 1}
  end

  # A logical line keeps one style for all of its wrapped segments;
  # continuation segments are indented two columns so a wrapped item still
  # reads as one. A {text, style} tuple carries an explicit color (the
  # color-coded dialogue rows); a bare string infers it (picked option
  # ">>"-led = accent, else strong) so string-only callers/tests are
  # unaffected.
  defp wrap_logical_line({text, style}, inner) when is_binary(text) do
    wrap_styled(text, style, inner)
  end

  defp wrap_logical_line(:rule, inner) do
    [{String.duplicate("─", inner), :muted}]
  end

  defp wrap_logical_line(line, inner) when is_binary(line) do
    style = if String.starts_with?(line, ">> "), do: :accent, else: :strong
    wrap_styled(line, style, inner)
  end

  defp wrap_styled(text, style, inner) do
    text
    |> wrap_text(inner)
    |> Enum.with_index()
    |> Enum.map(fn
      {seg, 0} -> {seg, style}
      {seg, _n} -> {"  " <> seg, style}
    end)
  end

  # Greedy word-wrap to a display width (CJK-aware via Screen.text_width). A
  # single token wider than the line is hard-split so nothing is ever lost.
  @doc false
  @spec wrap_text(String.t(), pos_integer()) :: [String.t()]
  def wrap_text(text, width) when is_binary(text) and is_integer(width) and width > 0 do
    {lines, cur} =
      text
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce({[], ""}, fn word, {lines, cur} ->
        cond do
          Screen.text_width(word) > width ->
            [head | tail] = hard_split(word, width)
            flushed = if cur == "", do: lines, else: [cur | lines]
            stack = Enum.reduce(Enum.drop(tail, -1), [head | flushed], &[&1 | &2])
            {stack, List.last(tail) || head}

          cur == "" ->
            {lines, word}

          Screen.text_width(cur) + 1 + Screen.text_width(word) <= width ->
            {lines, cur <> " " <> word}

          true ->
            {[cur | lines], word}
        end
      end)

    case Enum.reverse([cur | lines]) |> Enum.reject(&(&1 == "")) do
      [] -> [""]
      wrapped -> wrapped
    end
  end

  def wrap_text(text, _width) when is_binary(text), do: [text]
  def wrap_text(_text, _width), do: [""]

  defp hard_split("", _width), do: []

  defp hard_split(word, width) do
    # Guarantee forward progress: a width too small for the first (possibly
    # double-width) grapheme would make truncate/2 return "" and recurse
    # forever, so take at least one grapheme.
    chunk =
      case Screen.truncate(word, width) do
        "" -> String.first(word)
        c -> c
      end

    case String.replace_prefix(word, chunk, "") do
      "" -> [chunk]
      rest -> [chunk | hard_split(rest, width)]
    end
  end

  # Sections shrink to their content (min 1 body row for an idle/failed
  # placeholder), each capped at half the region so one cannot starve the
  # other; if both together overflow, parent yields to keep child visible.
  defp mcp_section_heights(parent_lines, child_lines, region) do
    overhead = 2
    half = max(div(region, 2), 1)
    p_body = min(max(length(parent_lines), 1), half)
    c_body = min(max(length(child_lines), 1), half)

    if p_body + overhead + c_body + overhead <= region do
      {p_body, c_body}
    else
      p = max(min(p_body, region - 2 * overhead - 1), 1)
      c = max(region - (p + overhead) - overhead, 1)
      {p, c}
    end
  end

  # Borderless sidebar block: a bold section header with a status token, then
  # dim content. No border/rule characters; whitespace separates the sidebar
  # from the conversation.
  defp draw_mcp_section(screen, x, y, w, title, lines, body_h) when w >= 4 and body_h >= 1 do
    {status, status_style} = mcp_section_status(lines)
    screen = Screen.put_text(screen, x, y, title, :p_title)

    screen =
      Screen.put_text(screen, x + String.length(title) + 1, y, status, status_style)

    rows =
      case lines do
        [] -> [{"idle", :p_muted}]
        lines -> lines |> Enum.take(-body_h) |> Enum.map(&{&1, mcp_line_style(&1)})
      end

    rows
    |> Enum.with_index(1)
    |> Enum.reduce(screen, fn {{text, style}, offset}, acc ->
      Screen.put_text(acc, x, y + offset, Screen.truncate(text, w - 1), style)
    end)
  end

  defp draw_mcp_section(screen, _x, _y, _w, _title, _lines, _body_h), do: screen

  defp draw_mcp_activity_section(screen, x, y, w, title, lines, body_h, scroll)
       when w >= 4 and body_h >= 1 do
    rows =
      lines
      |> scroll_tail(body_h, scroll)
      |> Enum.map(&{&1, :p_muted})

    screen
    |> Screen.put_text(x, y, title, :p_title)
    |> Screen.put_text(x + String.length(title) + 1, y, "live", :warn)
    |> then(fn screen ->
      rows
      |> Enum.with_index(1)
      |> Enum.reduce(screen, fn {{text, style}, offset}, acc ->
        Screen.put_text(acc, x, y + offset, Screen.truncate(text, w - 1), style)
      end)
    end)
  end

  defp draw_mcp_activity_section(screen, _x, _y, _w, _title, _lines, _body_h, _scroll),
    do: screen

  defp scroll_tail(lines, body_h, scroll) do
    total = length(lines)

    if total <= body_h do
      lines
    else
      offset = max(scroll, 0)
      start = max(total - body_h - offset, 0)
      lines |> Enum.slice(start, body_h)
    end
  end

  defp mcp_section_status([]), do: {"idle", :p_muted}

  defp mcp_section_status(lines) do
    cond do
      Enum.any?(lines, &(&1 =~ ~r/failed|error/i)) -> {"failed", :p_err}
      true -> {"live", :p_accent}
    end
  end

  defp mcp_line_style(line) do
    cond do
      line =~ ~r/failed|error/i -> :p_err
      line == "idle" -> :p_muted
      true -> :p_dim
    end
  end

  defp runtime_pane_lines(body, prefix) do
    body
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
    |> Enum.reject(&(&1 in ["empty", ""]))
    |> Enum.map(&humanize/1)
  end

  defp count_sessions(sections) do
    sections
    |> section_body("Parent/Child Sessions")
    |> Enum.count(&(&1 not in ["parent empty", "child empty", ""] and not region_marker?(&1)))
  end

  defp count_plugins(sections) do
    sections
    |> section_body("Plugin Status")
    |> Enum.count(&(&1 not in ["empty", ""] and not String.starts_with?(&1, "status=")))
  end

  defp section_body(sections, prefix) do
    Enum.find_value(sections, [], fn {title, body} ->
      if String.starts_with?(title, prefix), do: body, else: nil
    end)
  end

  defp status_fields(sections) do
    ["ourocode terminal", "State"]
    |> Enum.flat_map(&section_body(sections, &1))
    |> Enum.flat_map(&String.split(&1, " ", trim: true))
    |> Enum.reduce(%{}, fn token, acc ->
      case String.split(token, "=", parts: 2) do
        [k, v] when v != "" -> Map.put_new(acc, String.trim_trailing(k, "?"), v)
        _ -> acc
      end
    end)
  end

  # Strips machine `key=value` noise into a readable phrase while keeping the
  # SSoT projection as the upstream source of truth.
  defp humanize(line) do
    line
    |> String.replace(~r/\s+(region|x|y|w|h)=\S+/, "")
    |> String.replace("[OFFICIAL]", "OFFICIAL")
    |> String.replace("[THIRD-PARTY]", "THIRD-PARTY")
    |> String.replace(~r/\b(id|label|state|version|source)=/, "")
    |> String.replace(~r/\s{2,}/, " ")
    |> String.trim()
  end

  # The render model is the SSoT text projection; parsing it keeps the TUI
  # automatically in sync with every area renderer without duplicating them.
  def parse_sections(frame) do
    frame
    |> String.split("\n")
    |> Enum.reduce({[], nil}, fn line, {sections, current} ->
      cond do
        String.starts_with?(line, "+-- ") ->
          sections = flush_section(sections, current)
          {sections, {section_title(line), []}}

        line == "+--" ->
          {flush_section(sections, current), nil}

        String.starts_with?(line, "| ") and current != nil ->
          {title, body} = current
          content = String.trim_leading(line, "| ")

          if region_marker?(content) do
            {sections, current}
          else
            {sections, {title, [content | body]}}
          end

        true ->
          {sections, current}
      end
    end)
    |> then(fn {sections, current} -> flush_section(sections, current) end)
    |> Enum.reverse()
  end

  defp flush_section(sections, nil), do: sections

  defp flush_section(sections, {title, body}) do
    [{title, Enum.reverse(body)} | sections]
  end

  defp section_title(line) do
    line
    |> String.trim_leading("+-- ")
    |> String.split(" region=", parts: 2)
    |> List.first()
    |> String.split(" x=", parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp region_marker?(content) do
    Regex.match?(~r/^\[[a-z-]+-region\]\s+x=\d/, content)
  end
end
