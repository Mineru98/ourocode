defmodule Ourocode.Terminal.TuiState do
  @moduledoc """
  Agent-backed mutable state for the interactive TUI driver.
  """

  alias Ourocode.Terminal.{
    HistoryNavigation,
    Notifications,
    PromptStore,
    TuiFileCache,
    TuiStateInitial,
    WorkspaceNavigation
  }

  @double_press_ms 800
  @history_limit 50

  @spec start_link() :: pid()
  def start_link do
    {:ok, pid} = Agent.start_link(&TuiStateInitial.build/0)

    pid
  end

  @spec wonder_nav(pid()) :: map() | nil
  def wonder_nav(state), do: Agent.get(state, & &1.wonder_nav)

  @spec put_wonder_nav(pid(), map() | nil) :: :ok
  def put_wonder_nav(state, nav), do: Agent.update(state, &%{&1 | wonder_nav: nav})

  @spec force_interview_paused?(pid()) :: boolean()
  def force_interview_paused?(state),
    do: Agent.get(state, &Map.get(&1, :force_interview_paused, false))

  @spec put_force_interview_paused(pid(), boolean()) :: :ok
  def put_force_interview_paused(state, paused?),
    do: Agent.update(state, &Map.put(&1, :force_interview_paused, paused?))

  @spec interview_cancelled?(pid()) :: boolean()
  def interview_cancelled?(state),
    do: Agent.get(state, &Map.get(&1, :interview_cancelled, false))

  @spec put_interview_cancelled(pid(), boolean()) :: :ok
  def put_interview_cancelled(state, cancelled?),
    do: Agent.update(state, &Map.put(&1, :interview_cancelled, cancelled?))

  @spec scroll_off(pid()) :: non_neg_integer()
  def scroll_off(state), do: Agent.get(state, & &1.scroll)

  @spec put_scroll(pid(), integer()) :: :ok
  def put_scroll(state, value), do: Agent.update(state, &%{&1 | scroll: max(value, 0)})

  @spec scroll_by(pid(), integer()) :: :ok
  def scroll_by(state, delta), do: put_scroll(state, scroll_off(state) + delta)

  @spec workspace(pid()) :: map() | nil
  def workspace(state), do: Agent.get(state, &Map.get(&1, :workspace))

  @spec put_workspace(pid(), map() | nil) :: :ok
  def put_workspace(state, workspace),
    do: Agent.update(state, &Map.put(&1, :workspace, workspace))

  @spec workspace_active?(pid()) :: boolean()
  def workspace_active?(state), do: WorkspaceNavigation.active?(workspace(state))

  @spec move_workspace(pid(), -1 | 1) :: :ok
  def move_workspace(state, direction) do
    Agent.update(state, fn tui_state ->
      Map.put(
        tui_state,
        :workspace,
        WorkspaceNavigation.move(Map.get(tui_state, :workspace), direction)
      )
    end)
  end

  @spec workspace_enter_action(pid()) :: String.t() | nil
  def workspace_enter_action(state), do: WorkspaceNavigation.enter_action(workspace(state))

  @spec workspace_shortcut_action(pid(), String.t()) :: String.t() | nil
  def workspace_shortcut_action(state, shortcut),
    do: WorkspaceNavigation.shortcut_action(workspace(state), shortcut)

  @spec put_model_id(pid(), atom()) :: :ok
  def put_model_id(state, id), do: Agent.update(state, &%{&1 | model_id: id, model_cache: nil})

  @spec size(pid()) :: {pos_integer(), pos_integer()}
  def size(state), do: Agent.get(state, & &1.size)

  @spec put_size(pid(), {pos_integer(), pos_integer()}) :: :ok
  def put_size(state, wh), do: Agent.update(state, &%{&1 | size: wh})

  @spec mode(pid()) :: atom()
  def mode(state), do: Agent.get(state, & &1.mode)

  @spec put_mode(pid(), atom()) :: :ok
  def put_mode(state, mode), do: Agent.update(state, &%{&1 | mode: mode})

  @spec pidx(pid()) :: integer()
  def pidx(state), do: Agent.get(state, & &1.pidx)

  @spec put_pidx(pid(), integer()) :: :ok
  def put_pidx(state, index), do: Agent.update(state, &%{&1 | pidx: index})

  @spec login(pid()) :: map() | nil
  def login(state), do: Agent.get(state, & &1.login)

  @spec put_login(pid(), map() | nil) :: :ok
  def put_login(state, login), do: Agent.update(state, &%{&1 | login: login, model_cache: nil})

  @spec streaming?(pid()) :: boolean()
  def streaming?(state), do: Agent.get(state, & &1.streaming)

  @spec set_streaming(pid(), boolean()) :: :ok
  def set_streaming(state, on), do: Agent.update(state, &%{&1 | streaming: on})

  @spec live_turn_event(pid()) :: map() | nil
  def live_turn_event(state), do: Agent.get(state, &Map.get(&1, :live_turn_event))

  @spec put_live_turn_event(pid(), map() | nil) :: :ok
  def put_live_turn_event(state, event),
    do: Agent.update(state, &Map.put(&1, :live_turn_event, event))

  @spec key_help?(pid()) :: boolean()
  def key_help?(state), do: Agent.get(state, & &1.key_help)

  @spec toggle_key_help(pid()) :: :ok
  def toggle_key_help(state), do: Agent.update(state, &%{&1 | key_help: not &1.key_help})

  @spec tick(pid()) :: non_neg_integer()
  def tick(state), do: Agent.get(state, & &1.tick)

  @spec bump_tick(pid()) :: :ok
  def bump_tick(state), do: Agent.update(state, &%{&1 | tick: &1.tick + 1})

  @spec file_cache(pid()) :: [String.t()]
  def file_cache(state), do: TuiFileCache.get_or_start(state, self())

  @spec put_file_cache(pid(), [String.t()]) :: :ok
  def put_file_cache(state, files), do: TuiFileCache.put(state, files)

  @spec notifications(pid()) :: [String.t()]
  def notifications(state) do
    now = System.monotonic_time(:millisecond)
    Agent.get_and_update(state, &Notifications.active(&1, now))
  end

  @spec push_notification(pid(), String.t(), pos_integer()) :: :ok
  def push_notification(state, text, ttl_ms \\ 1_500) do
    now = System.monotonic_time(:millisecond)
    Agent.update(state, &Notifications.push(&1, text, now, ttl_ms))
  end

  @spec port(pid()) :: port() | nil
  def port(state), do: Agent.get(state, & &1.port)

  @spec put_port(pid(), port() | nil) :: :ok
  def put_port(state, port), do: Agent.update(state, &%{&1 | port: port})

  @spec put_inbuf(pid(), binary()) :: :ok
  def put_inbuf(state, bytes), do: Agent.update(state, &%{&1 | inbuf: bytes})

  @spec take_inbuf(pid()) :: binary()
  def take_inbuf(state), do: Agent.get_and_update(state, &{&1.inbuf, %{&1 | inbuf: ""}})

  @spec buffer(pid()) :: String.t()
  def buffer(state), do: Agent.get(state, & &1.buffer)

  @spec cursor(pid()) :: non_neg_integer()
  def cursor(state), do: Agent.get(state, & &1.cursor)

  @spec edit_buffer(pid(), map()) :: :ok
  def edit_buffer(state, event) do
    Agent.update(state, fn s ->
      s = Ourocode.Terminal.InputEditor.edit_state(s, event)
      PromptStore.save_draft(s.buffer)
      s
    end)
  end

  @spec handle_escape_clear(pid()) :: :ok
  def handle_escape_clear(state) do
    now = System.monotonic_time(:millisecond)

    Agent.update(state, fn s ->
      cond do
        s.buffer == "" ->
          s
          |> Notifications.clear()
          |> Map.put(:esc_armed_until, nil)

        is_integer(s.esc_armed_until) and s.esc_armed_until >= now ->
          s
          |> Map.merge(%{
            buffer: "",
            cursor: 0,
            history_index: 0,
            history_draft: nil,
            esc_armed_until: nil
          })
          |> Notifications.push("input cleared", now, 1_000)

        true ->
          s
          |> Map.put(:esc_armed_until, now + @double_press_ms)
          |> Notifications.push("Esc again to clear input", now, @double_press_ms)
      end
    end)

    PromptStore.save_draft(buffer(state))
  end

  @spec remember_history(pid(), String.t()) :: :ok
  def remember_history(_state, ""), do: :ok

  def remember_history(state, line) when is_binary(line) do
    Agent.update(state, &HistoryNavigation.remember(&1, line, @history_limit))
    PromptStore.append_history(line)
  end

  @spec move_history(pid(), -1 | 1) :: :ok
  def move_history(state, direction) when direction in [-1, 1] do
    Agent.update(state, &HistoryNavigation.move(&1, direction))
  end

  @spec reset_history_cursor(pid()) :: :ok
  def reset_history_cursor(state), do: Agent.update(state, &HistoryNavigation.reset/1)

  @spec take_buffer(pid()) :: String.t()
  def take_buffer(state) do
    PromptStore.clear_draft()
    Agent.get_and_update(state, fn s -> {s.buffer, %{s | buffer: "", cursor: 0}} end)
  end

  @spec take_leftover(pid()) :: binary()
  def take_leftover(state) do
    Agent.get_and_update(state, fn s -> {s.leftover, %{s | leftover: ""}} end)
  end

  @spec put_leftover(pid(), binary()) :: :ok
  def put_leftover(state, leftover),
    do: Agent.update(state, fn s -> %{s | leftover: leftover} end)

  @spec prev_screen(pid()) :: term()
  def prev_screen(state), do: Agent.get(state, & &1.prev_screen)

  @spec put_prev_screen(pid(), term()) :: :ok
  def put_prev_screen(state, screen) do
    Agent.update(state, fn s -> %{s | prev_screen: screen} end)
  end

  @spec render_theme(pid()) :: :dark | :light | nil
  def render_theme(state), do: Agent.get(state, &Map.get(&1, :render_theme))

  @spec put_render_theme(pid(), :dark | :light | nil) :: :ok
  def put_render_theme(state, theme) when theme in [:dark, :light, nil] do
    Agent.update(state, fn s -> Map.put(s, :render_theme, theme) end)
  end
end
