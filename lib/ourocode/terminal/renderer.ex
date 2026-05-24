defmodule Ourocode.Terminal.Renderer do
  @moduledoc false

  alias Ourocode.Terminal.{
    FrameSections,
    RendererChrome,
    RendererInterview,
    RendererLoginCard,
    RendererOverlaySlot,
    RendererPausedInterview,
    RendererTranscript,
    RuntimeSplit,
    Screen
  }

  @min_width 40
  @min_height 16

  def compose(columns, rows, sections, activity, prompt_buffer, opts) do
    width = max(columns, @min_width)
    height = max(rows, @min_height)
    kv = FrameSections.status_fields(sections)
    mode = Map.get(opts, :mode, :normal)
    login = Map.get(opts, :login)
    palette = Map.get(opts, :palette)
    model_overlay = Map.get(opts, :model)
    interview_block = Map.get(opts, :interview_block)
    wonder_focus = Map.get(opts, :wonder_focus, false)
    reasoning = Map.get(opts, :interview_reasoning, [])
    mcp_activity = Map.get(opts, :mcp_activity, [])
    activity = RendererPausedInterview.activity(activity, opts)
    interview_present? = match?({_marker, _lines, _hint}, interview_block)
    interview_owns_left? = interview_present? and not Map.get(opts, :interview_paused, false)
    body_activity = if interview_owns_left?, do: [], else: activity
    palette = RendererPausedInterview.palette(palette, prompt_buffer, opts)

    overlay_slot =
      prompt_buffer
      |> RendererOverlaySlot.build(
        mode,
        Map.merge(opts, %{palette: palette, model: model_overlay})
      )

    composer_rule = height - 3
    transcript_top = 4
    transcript_bottom = composer_rule - 2

    screen =
      Screen.new(width, height)
      |> RendererChrome.draw_header(width, kv, opts)

    scroll = Map.get(opts, :scroll, 0)
    split? = RuntimeSplit.mcp_active?(sections) or reasoning != [] or mcp_activity != []

    # A live picker is an intentional checkpoint: mute the rest of the body
    # and let the decision UI own the available space so it cannot be missed.
    screen =
      if wonder_focus and interview_present? do
        RendererInterview.draw_focus(
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
          left_w = RuntimeSplit.split_left_width(width)

          block_w =
            if reasoning == [] and not RuntimeSplit.mcp_active?(sections), do: width, else: left_w

          max_rows = max(transcript_bottom - transcript_top - 1, 1)

          {screen, used} =
            RendererInterview.draw_block(
              screen,
              transcript_top,
              block_w,
              marker,
              lines,
              hint,
              max_rows
            )

          {screen, transcript_top + used + 1}
      end

    screen =
      cond do
        wonder_focus and interview_present? ->
          screen

        login ->
          RendererLoginCard.draw(screen, width, transcript_top, transcript_bottom, login)

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

    screen = RendererOverlaySlot.draw(screen, width, transcript_bottom, overlay_slot)

    screen
    |> RendererChrome.draw_composer(width, composer_rule, prompt_buffer, mode, opts)
    |> RendererChrome.draw_status_bar(width, height - 1, kv, sections, mode, opts)
  end

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
    RendererTranscript.draw(
      screen,
      width,
      top,
      bottom,
      activity,
      show_empty_hint,
      scroll,
      clip_override
    )
  end

  # Left: scrollable conversation transcript. Right: MCP internals, parent
  # workflow on top, child session stream on the bottom. The split is what
  # makes streaming legible instead of a flat interleaved log.
  # Borderless sidebar style: one dim vertical rule is the only separator; the
  # right column is a bare titled telemetry sidebar whose sections size to
  # their content, not to the region. A too-narrow terminal collapses cleanly
  # back to a single full-width transcript.
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
    RuntimeSplit.draw(
      screen,
      width,
      left_top,
      right_top,
      bottom,
      activity,
      sections,
      scroll,
      reasoning,
      mcp_activity,
      &RendererTranscript.draw/8
    )
  end

  # Greedy word-wrap to a display width (CJK-aware via Screen.text_width). A
  # single token wider than the line is hard-split so nothing is ever lost.
  @doc false
  @spec wrap_text(String.t(), pos_integer()) :: [String.t()]
  def wrap_text(text, width), do: RendererInterview.wrap_text(text, width)

  # The render model is the SSoT text projection; parsing it keeps the TUI
  # automatically in sync with every area renderer without duplicating them.
  def parse_sections(frame), do: FrameSections.parse(frame)
end
