defmodule Ourocode.Terminal.TuiCompletions do
  @moduledoc """
  Completion and suggestion state for the raw TUI composer.
  """

  alias Ourocode.Terminal.{Fuzzy, Palette, Suggestions, TuiState}

  @ooo_cache_ttl_ms 30_000

  @spec ooo_commands(pid(), boolean()) :: [map()]
  def ooo_commands(state, test_run?) when is_pid(state) and is_boolean(test_run?) do
    now = System.monotonic_time(:millisecond)

    Agent.get_and_update(state, fn tui_state ->
      fresh? =
        is_list(tui_state.ooo_cache) and
          is_integer(Map.get(tui_state, :ooo_cache_loaded_ms)) and
          now - tui_state.ooo_cache_loaded_ms < @ooo_cache_ttl_ms

      commands =
        if fresh?, do: tui_state.ooo_cache, else: Suggestions.build_ooo_commands(test_run?)

      {commands, %{tui_state | ooo_cache: commands, ooo_cache_loaded_ms: now}}
    end)
  end

  @spec ooo_suggesting?(pid(), boolean()) :: boolean()
  def ooo_suggesting?(state, test_run?) do
    prompt_buffer = TuiState.buffer(state)

    Suggestions.ooo_prompt?(prompt_buffer) and
      not Suggestions.completed_ooo_command?(
        prompt_buffer,
        ooo_commands(state, test_run?)
      ) and
      Suggestions.ooo_suggestions(prompt_buffer, :normal, false, ooo_commands(state, test_run?)) !=
        []
  end

  @spec ooo_choice(String.t(), integer(), pid(), boolean()) :: String.t()
  def ooo_choice(prompt_buffer, index, state, test_run?) do
    Suggestions.ooo_choice(prompt_buffer, index, ooo_commands(state, test_run?))
  end

  @spec file_mention_suggestions(pid(), atom(), boolean()) :: [{String.t(), term()}]
  def file_mention_suggestions(state, :normal, false) do
    case active_file_mention_query(TuiState.buffer(state), TuiState.cursor(state)) do
      nil ->
        []

      query ->
        state
        |> TuiState.file_cache()
        |> Enum.map(fn path -> {path, {path, Suggestions.file_label(path)}} end)
        |> Fuzzy.rank(query, limit: 8)
    end
  end

  def file_mention_suggestions(_state, _mode, _wonder_focus), do: []

  @spec file_mention_suggesting?(pid()) :: boolean()
  def file_mention_suggesting?(state) do
    file_mention_suggestions(state, TuiState.mode(state), false) != []
  end

  @spec insert_file_mention_choice(pid()) :: :ok
  def insert_file_mention_choice(state) do
    suggestions = file_mention_suggestions(state, TuiState.mode(state), false)
    clamped = Palette.clamp(TuiState.pidx(state), length(suggestions))

    case Enum.at(suggestions, clamped) do
      {path, _label} ->
        Agent.update(state, fn tui_state ->
          {buffer, cursor} =
            Suggestions.replace_active_file_mention(tui_state.buffer, tui_state.cursor, path)

          %{tui_state | buffer: buffer, cursor: cursor}
        end)

      _none ->
        :ok
    end
  end

  @spec insert_ooo_choice(pid(), boolean()) :: :ok
  def insert_ooo_choice(state, test_run?) when is_pid(state) and is_boolean(test_run?) do
    choice =
      state
      |> TuiState.buffer()
      |> ooo_choice(TuiState.pidx(state), state, test_run?)

    Agent.update(state, fn tui_state ->
      buffer = choice <> " "
      %{tui_state | buffer: buffer, cursor: String.length(buffer), pidx: 0}
    end)
  end

  @spec insert_active_choice(pid(), boolean()) :: boolean()
  def insert_active_choice(state, test_run?) when is_pid(state) and is_boolean(test_run?) do
    cond do
      file_mention_suggesting?(state) ->
        insert_file_mention_choice(state)
        TuiState.put_pidx(state, 0)
        true

      ooo_suggesting?(state, test_run?) ->
        insert_ooo_choice(state, test_run?)
        true

      true ->
        false
    end
  end

  @spec active_file_mention_query(String.t(), non_neg_integer()) :: String.t() | nil
  def active_file_mention_query(prompt_buffer, cursor) when is_binary(prompt_buffer) do
    Suggestions.active_file_mention_query(prompt_buffer, cursor)
  end
end
