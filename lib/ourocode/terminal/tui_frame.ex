defmodule Ourocode.Terminal.TuiFrame do
  @moduledoc """
  Frame composition and redraw helpers for the interactive TUI.
  """

  alias Ourocode.Terminal.{
    Palette,
    LiveResult,
    LiveTurnActivity,
    Screen,
    ScreenStyles,
    ShellRenderer,
    Suggestions,
    TuiCompletions,
    TuiDriverSession,
    TuiInteraction,
    TuiModelSelection,
    TuiState,
    WorkspaceText
  }

  @min_width 40
  @min_height 16
  @body 4

  @spec frame_lines(String.t(), [String.t()], String.t(), pos_integer(), pos_integer(), map()) ::
          [String.t()]
  def frame_lines(frame, activity, prompt_buffer, columns, rows, opts \\ %{})
      when is_binary(frame) and is_list(activity) and is_binary(prompt_buffer) do
    workspace_active? = workspace_active_from_opts?(opts)
    activity = opts_workspace_activity(opts) || activity
    opts = Map.put(opts, :workspace_active, workspace_active?)

    frame
    |> parse_sections()
    |> then(&compose(columns, rows, &1, activity, prompt_buffer, opts))
    |> Screen.to_lines()
  end

  @spec redraw(map(), pid(), pid(), String.t(), pos_integer(), pos_integer(), keyword()) :: :ok
  def redraw(result, output, state, prompt_buffer, columns, rows, opts \\ []) do
    TuiState.bump_tick(state)

    result =
      result
      |> LiveResult.result()
      |> display_result(state)

    sections = parse_sections(ShellRenderer.render_initial_frame(result))
    activity = workspace_activity(state) || activity_lines(output)

    nav = sync_wonder_nav(state, result)

    interview_block = interview_block_lines(result, nav, TuiState.tick(state))
    interview_reasoning = interview_reasoning_lines(result, TuiState.tick(state))
    mcp_activity = mcp_activity_lines(result)

    view_opts =
      state
      |> view_opts(opts)
      |> Map.put(:interview_block, interview_block)
      |> Map.put(:interview_reasoning, interview_reasoning)
      |> Map.put(:mcp_activity, mcp_activity)
      |> Map.put(
        :wonder_focus,
        TuiInteraction.wonder_active?(result) and not TuiInteraction.paused?(result)
      )
      |> Map.put(:interview_paused, TuiInteraction.paused?(result))
      |> Map.put(:workspace_active, TuiState.workspace_active?(state))

    maybe_complete_live_turn(state, view_opts)

    screen = compose(columns, rows, sections, activity, prompt_buffer, view_opts)

    theme = ScreenStyles.theme()
    previous_screen = previous_screen_for_theme(state, theme)
    {iodata, screen} = Screen.diff(previous_screen, screen)
    TuiState.put_prev_screen(state, screen)
    TuiState.put_render_theme(state, theme)
    TuiDriverSession.write(state, iodata)
    cursor_to_prompt(state, rows, columns, prompt_buffer, view_opts)
  end

  @doc false
  @spec previous_screen_for_theme(pid(), :dark | :light) :: term() | nil
  def previous_screen_for_theme(state, theme) do
    if TuiState.render_theme(state) == theme do
      TuiState.prev_screen(state)
    end
  end

  defp display_result(result, state) do
    cond do
      TuiState.interview_cancelled?(state) ->
        result
        |> Map.delete(:wonder_tool)
        |> Map.update(:interview, nil, fn
          %{} = interview -> Map.put(interview, :complete, :user_done)
          other -> other
        end)

      TuiState.force_interview_paused?(state) ->
        Map.put(result, :paused, true)

      true ->
        result
    end
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
      live_turn_activity:
        LiveTurnActivity.view(TuiState.live_turn_event(state), TuiState.tick(state)),
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

  defp maybe_complete_live_turn(state, opts) do
    if TuiState.live_turn_event(state) && live_turn_surface_ready?(opts) do
      TuiState.put_live_turn_event(state, nil)
    end
  end

  defp live_turn_surface_ready?(opts) do
    Map.get(opts, :workspace_active, false) or
      match?({_marker, _lines, _hint}, Map.get(opts, :interview_block)) or
      Map.get(opts, :mcp_activity, []) != [] or
      Map.get(opts, :interview_reasoning, []) != []
  end

  defp compose(columns, rows, sections, activity, prompt_buffer, opts) do
    Ourocode.Terminal.Renderer.compose(columns, rows, sections, activity, prompt_buffer, opts)
  end

  defp parse_sections(frame), do: Ourocode.Terminal.Renderer.parse_sections(frame)

  defp activity_lines(output) do
    {_input, captured} = StringIO.contents(output)

    String.split(captured, "\n", trim: true)
  end

  defp workspace_activity(state) do
    case TuiState.workspace(state) do
      workspace when is_map(workspace) ->
        workspace
        |> WorkspaceText.render()
        |> String.split("\n", trim: true)

      _none ->
        nil
    end
  end

  defp opts_workspace_activity(%{workspace: workspace}) when is_map(workspace) do
    workspace
    |> WorkspaceText.render()
    |> String.split("\n", trim: true)
  end

  defp opts_workspace_activity(_opts), do: nil

  defp workspace_active_from_opts?(%{workspace: workspace}), do: is_map(workspace)
  defp workspace_active_from_opts?(opts), do: Map.get(opts, :workspace_active, false)

  defp cursor_to_prompt(state, rows, columns, prompt_buffer, opts) do
    height = max(rows, @min_height)
    width = max(columns, @min_width)

    prefix =
      prompt_buffer |> String.graphemes() |> Enum.take(TuiState.cursor(state)) |> Enum.join()

    prompt_start_col = prompt_text_column(opts)
    ansi_row = height - 1
    ansi_col = min(prompt_start_col + Screen.text_width(prefix), width)
    TuiDriverSession.write(state, "\e[#{ansi_row};#{ansi_col}H\e[?25h")
  end

  defp prompt_text_column(opts) do
    live_activity? = Map.get(opts, :live_turn_activity, []) != []

    if live_activity? or Map.get(opts, :streaming, false) do
      @body + 4 + 1
    else
      @body + 1
    end
  end
end
