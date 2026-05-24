defmodule Ourocode.Terminal.TuiFrame do
  @moduledoc """
  Frame composition and redraw helpers for the interactive TUI.
  """

  alias Ourocode.Terminal.{
    Palette,
    LiveResult,
    Screen,
    ShellRenderer,
    Suggestions,
    TuiCompletions,
    TuiDriverSession,
    TuiInteraction,
    TuiModelSelection,
    TuiState
  }

  @min_width 40
  @min_height 16
  @body 4

  @spec frame_lines(String.t(), [String.t()], String.t(), pos_integer(), pos_integer(), map()) ::
          [String.t()]
  def frame_lines(frame, activity, prompt_buffer, columns, rows, opts \\ %{})
      when is_binary(frame) and is_list(activity) and is_binary(prompt_buffer) do
    frame
    |> parse_sections()
    |> then(&compose(columns, rows, &1, activity, prompt_buffer, opts))
    |> Screen.to_lines()
  end

  @spec redraw(map(), pid(), pid(), String.t(), pos_integer(), pos_integer(), keyword()) :: :ok
  def redraw(result, output, state, prompt_buffer, columns, rows, opts \\ []) do
    TuiState.bump_tick(state)
    sections = parse_sections(ShellRenderer.render_initial_frame(LiveResult.result(result)))
    activity = activity_lines(output)

    nav = sync_wonder_nav(state, result)

    view_opts =
      state
      |> view_opts(opts)
      |> Map.put(:interview_block, interview_block_lines(result, nav, TuiState.tick(state)))
      |> Map.put(:interview_reasoning, interview_reasoning_lines(result, TuiState.tick(state)))
      |> Map.put(:mcp_activity, mcp_activity_lines(result))
      |> Map.put(
        :wonder_focus,
        TuiInteraction.wonder_active?(result) and not TuiInteraction.paused?(result)
      )
      |> Map.put(:interview_paused, TuiInteraction.paused?(result))

    screen = compose(columns, rows, sections, activity, prompt_buffer, view_opts)

    {iodata, screen} = Screen.diff(TuiState.prev_screen(state), screen)
    TuiState.put_prev_screen(state, screen)
    TuiDriverSession.write(state, iodata)
    cursor_to_prompt(state, rows, columns, prompt_buffer)
  end

  @spec view_opts(pid(), keyword()) :: map()
  def view_opts(state, opts \\ []) do
    mode = TuiState.mode(state)
    test_run? = Keyword.get(opts, :test_run?, fn -> false end)
    auth_label = Keyword.get(opts, :auth_label, fn _state -> "" end)

    %{
      mode: mode,
      login: TuiState.login(state),
      streaming: TuiState.streaming?(state),
      key_help: TuiState.key_help?(state),
      tick: TuiState.tick(state),
      scroll: TuiState.scroll_off(state),
      pidx: TuiState.pidx(state),
      auth: auth_label.(state),
      notifications: TuiState.notifications(state),
      ooo_commands:
        if mode == :normal and Suggestions.ooo_prompt?(TuiState.buffer(state)) do
          TuiCompletions.ooo_commands(state, test_run?.())
        else
          nil
        end,
      palette:
        if mode == :palette do
          entries = Palette.filter(Palette.entries(), TuiState.buffer(state))
          %{entries: entries, index: Palette.clamp(TuiState.pidx(state), length(entries))}
        else
          nil
        end,
      model:
        if mode == :model do
          TuiModelSelection.overlay(state)
        else
          nil
        end,
      file_mentions: TuiCompletions.file_mention_suggestions(state, mode, false)
    }
  end

  defp interview_block_lines(result, nav, tick) do
    Ourocode.Terminal.InterviewPanel.interview_block_lines(result, nav, tick)
  end

  defp sync_wonder_nav(state, result) do
    case TuiInteraction.wonder_detection(result) do
      nil ->
        TuiState.put_wonder_nav(state, nil)
        nil

      detection ->
        nav = TuiState.wonder_nav(state)
        nav = Ourocode.Terminal.InterviewPanel.default_nav(detection, nav)

        TuiState.put_wonder_nav(state, nav)
        nav
    end
  rescue
    _exception -> nil
  end

  defp interview_reasoning_lines(result, tick) do
    Ourocode.Terminal.InterviewPanel.interview_reasoning_lines(result, tick)
  end

  defp mcp_activity_lines(result) do
    Ourocode.Terminal.InterviewPanel.mcp_activity_lines(result)
  end

  defp compose(columns, rows, sections, activity, prompt_buffer, opts) do
    Ourocode.Terminal.Renderer.compose(columns, rows, sections, activity, prompt_buffer, opts)
  end

  defp parse_sections(frame), do: Ourocode.Terminal.Renderer.parse_sections(frame)

  defp activity_lines(output) do
    {_input, captured} = StringIO.contents(output)

    String.split(captured, "\n", trim: true)
  end

  defp cursor_to_prompt(state, rows, columns, prompt_buffer) do
    height = max(rows, @min_height)
    width = max(columns, @min_width)

    prefix =
      prompt_buffer |> String.graphemes() |> Enum.take(TuiState.cursor(state)) |> Enum.join()

    ansi_row = height - 1
    ansi_col = min(@body + 1 + Screen.text_width(prefix), width)
    TuiDriverSession.write(state, "\e[#{ansi_row};#{ansi_col}H\e[?25h")
  end
end
