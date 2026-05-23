defmodule Ourocode.Terminal.Tui do
  @moduledoc """
  Interactive terminal frontend driver.

  This is the seed's optional, replaceable high-performance frontend piece:
  it owns raw-mode input, the alternate screen, and an in-place colored
  redraw, while the Elixir runtime stays the single source of truth. It
  attaches only at the existing `EventLoop` input/output seam, so the loop
  logic, the data/journal model, and every non-interactive (piped, smoke,
  test) path stay byte-for-byte unchanged.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Catalog
  alias Ourocode.Provider.Codex
  alias Ourocode.Terminal.{KeyReader, Palette, PromptStore, Screen, ShellRenderer, Suggestions}

  @prompt "ourocode> "
  @min_width 40
  @min_height 16
  @body 4
  @model_cache_ttl_ms 2_000

  @doc """
  Returns true only for a real interactive terminal session.

  Piped input, captured `StringIO` devices (tests), and the non-interactive
  smoke path all fall back to the plain line renderer.
  """
  @spec interactive?(map() | keyword()) :: boolean()
  def interactive?(options) do
    options = Map.new(options)
    input = Map.get(options, :input, :stdio)
    output = Map.get(options, :output, :stdio)

    stdio_device?(input) and stdio_device?(output) and Map.get(options, :read_line) == nil and
      not test_run?() and tty?() and helper_path() != nil
  end

  # A live ExUnit server means we are inside the test runner; never claim a
  # raw terminal there even if the developer runs `mix test` from a real tty.
  defp test_run?, do: is_pid(Process.whereis(ExUnit.Server))

  @doc """
  Runs the interactive flow with the TUI attached to the event loop.

  The terminal is always restored, even if the loop raises or exits.
  """
  @spec run(map(), map() | keyword(), (map(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def run(result, options, loop_fun) when is_function(loop_fun, 2) do
    {:ok, output} = StringIO.open("")
    state = start_state()

    case start_driver(state) do
      :ok ->
        try do
          {columns, rows} = refresh_size(state)
          redraw(result, output, state, "", columns, rows)

          read_line = fn _prompt -> read_key_line(result, output, state) end

          loop_options =
            options
            |> Map.new()
            |> Map.put(:output, output)
            |> Map.put(:read_line, read_line)
            |> Map.put(:prompt, @prompt)
            |> attach_active_model_provider(state)

          loop_fun.(result, loop_options)
        after
          stop_driver(state)
          StringIO.close(output)
          Agent.stop(state)
        end

      :error ->
        StringIO.close(output)
        Agent.stop(state)
        # No native helper: fall back to the plain line renderer + loop.
        ShellRenderer.draw_initial_frame(result, Map.get(Map.new(options), :output, :stdio))
        loop_fun.(result, options)
    end
  end

  defp attach_active_model_provider(options, state) do
    case Map.get(options, :on_prompt_input) do
      fun when is_function(fun, 3) ->
        Map.put(options, :on_prompt_input, fn task_request, input_event, startup_result ->
          input_event =
            input_event
            |> Map.put(:active_model, active_model(state))
            |> put_in([:payload, :active_model_id], active_model(state).id)

          fun.(task_request, input_event, startup_result)
        end)

      _other ->
        options
    end
  end

  defp read_key_line(result, output, state) do
    {columns, rows} = refresh_size(state)
    redraw(result, output, state, buffer(state), columns, rows)
    read_key_loop(result, output, state)
  end

  defp read_key_loop(result, output, state) do
    case next_chunk(state) do
      :eof ->
        :eof

      :tick ->
        {columns, rows} = refresh_size(state)
        redraw(result, output, state, buffer(state), columns, rows)
        read_key_loop(result, output, state)

      {:ok, chunk} ->
        {columns, rows} = refresh_size(state)
        {events, leftover} = KeyReader.decode(take_leftover(state) <> chunk)
        put_leftover(state, leftover)

        case apply_events(events, result, output, state, columns, rows) do
          {:submit, line} -> line
          :exit -> :eof
          :continue -> read_key_loop(result, output, state)
        end
    end
  end

  defp apply_events([], _result, _output, _state, _columns, _rows), do: :continue

  defp apply_events([event | rest], result, output, state, columns, rows) do
    cont = fn -> apply_events(rest, result, output, state, columns, rows) end
    draw = fn -> redraw(result, output, state, buffer(state), columns, rows) end

    cond do
      match?(%{key: :ctrl_c}, event) ->
        :exit

      # A live wonderTool checkpoint is a real picker: Up/Dn move the option
      # cursor, Tab advances to the next question, and a bare 1-9 (only when
      # the composer is empty, so free-typing still works) jumps the cursor.
      interaction_capturing?(result) and wonder_active?(result) and
          wonder_nav_event?(event, buffer(state), result, state) ->
        handle_wonder_nav(event, result, state)
        draw.()
        cont.()

      # While a checkpoint is live (and not paused), Enter submits (all picks
      # for a wonderTool, or the typed free answer) and Esc pauses; every other
      # key still edits the composer so a free-text answer stays possible.
      interaction_capturing?(result) and match?(%{key: k} when k in [:enter, :escape], event) ->
        handle_interaction_event(event, result, output, state)
        draw.()
        cont.()

      true ->
        apply_normal_event(event, result, output, state, columns, rows, cont, draw)
    end
  end

  defp apply_normal_event(event, result, output, state, columns, rows, cont, draw) do
    case {get_mode(state), event} do
      {_mode, %{key: :ctrl_c}} ->
        :exit

      {_mode, %{key: k}} when k in [:cmd_plus, :cmd_minus] ->
        # The host terminal owns zoom. Refreshing size on the next redraw keeps
        # the alternate-screen layout aligned without inserting stray input.
        draw.()
        cont.()

      # --- palette mode -------------------------------------------------
      {_mode, %{key: :ctrl_g}} ->
        toggle_key_help(state)
        draw.()
        cont.()

      {:palette, %{key: :escape}} ->
        close_palette(state)
        draw.()
        cont.()

      {:palette, %{key: down}} when down in [:down, :tab] ->
        put_pidx(state, pidx(state) + 1)
        draw.()
        cont.()

      {:palette, %{key: :up}} ->
        put_pidx(state, pidx(state) - 1)
        draw.()
        cont.()

      {:palette, %{key: :enter}} ->
        line = palette_choice(state)
        close_palette(state)

        case handle_enter(line, result, output, state, columns, rows) do
          {:submit, l} -> {:submit, l}
          :continue -> cont.()
          :exit -> :exit
        end

      {:palette, %{key: :backspace}} ->
        edit_buffer(state, event)
        if buffer(state) == "", do: close_palette(state)
        put_pidx(state, 0)
        draw.()
        cont.()

      {:palette, %{key: k}}
      when k in [
             :delete,
             :left,
             :right,
             :home,
             :end,
             :ctrl_a,
             :ctrl_b,
             :ctrl_d,
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
           ] ->
        edit_buffer(state, event)
        if buffer(state) == "", do: close_palette(state)
        put_pidx(state, 0)
        draw.()
        cont.()

      {:palette, %{key: :char, char: g}} when is_binary(g) ->
        edit_buffer(state, event)
        put_pidx(state, 0)
        draw.()
        cont.()

      {:palette, %{key: :paste, char: text}} when is_binary(text) ->
        edit_buffer(state, event)
        put_pidx(state, 0)
        draw.()
        cont.()

      # --- model picker -------------------------------------------------
      {:model, %{key: :escape}} ->
        close_palette(state)
        draw.()
        cont.()

      {:model, %{key: k}} when k in [:down, :tab] ->
        put_pidx(state, pidx(state) + 1)
        draw.()
        cont.()

      {:model, %{key: :up}} ->
        put_pidx(state, pidx(state) - 1)
        draw.()
        cont.()

      {:model, %{key: :enter}} ->
        choose_model(result, output, state, columns, rows)
        cont.()

      {:model, %{key: :backspace}} ->
        close_palette(state)
        draw.()
        cont.()

      {:model, _ignored_model_key} ->
        cont.()

      # --- normal mode --------------------------------------------------
      {:normal, %{key: down}} when down in [:down, :tab, :ctrl_n] ->
        cond do
          file_mention_suggesting?(state) ->
            put_pidx(state, pidx(state) + 1)
            draw.()

          ooo_suggesting?(state) ->
            put_pidx(state, pidx(state) + 1)
            draw.()

          true ->
            move_history(state, 1)
            draw.()
        end

        cont.()

      {:normal, %{key: up}} when up in [:up, :ctrl_p] ->
        cond do
          file_mention_suggesting?(state) ->
            put_pidx(state, pidx(state) - 1)
            draw.()

          ooo_suggesting?(state) ->
            put_pidx(state, pidx(state) - 1)
            draw.()

          true ->
            move_history(state, -1)
            draw.()
        end

        cont.()

      {:normal, %{key: :char, char: "/"}} ->
        if buffer(state) == "" do
          put_mode(state, :palette)
          put_pidx(state, 0)
        end

        edit_buffer(state, event)
        reset_history_cursor(state)
        draw.()
        cont.()

      {:normal, %{key: :enter}} ->
        cond do
          file_mention_suggesting?(state) ->
            insert_file_mention_choice(state)
            put_pidx(state, 0)
            draw.()
            cont.()

          true ->
            line =
              if ooo_suggesting?(state) do
                ooo_choice(buffer(state), pidx(state), state)
              else
                String.trim(buffer(state))
              end

            _ = take_buffer(state)
            put_pidx(state, 0)
            remember_history(state, line)

            case handle_enter(line, result, output, state, columns, rows) do
              {:submit, line} -> {:submit, line}
              :continue -> cont.()
              :exit -> :exit
            end
        end

      {:normal, %{key: :backspace}} ->
        edit_buffer(state, event)
        put_pidx(state, 0)
        reset_history_cursor(state)
        draw.()
        cont.()

      {:normal, %{key: :ctrl_d}} ->
        if buffer(state) == "" do
          :exit
        else
          edit_buffer(state, event)
          put_pidx(state, 0)
          reset_history_cursor(state)
          draw.()
          cont.()
        end

      {:normal, %{key: :escape}} ->
        handle_escape_clear(state)
        draw.()
        cont.()

      {:normal, %{key: k}}
      when k in [
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
           ] ->
        edit_buffer(state, event)
        put_pidx(state, 0)
        reset_history_cursor(state)
        draw.()
        cont.()

      {:normal, %{key: :char, char: g}} when is_binary(g) ->
        edit_buffer(state, event)
        put_pidx(state, 0)
        reset_history_cursor(state)
        draw.()
        cont.()

      {:normal, %{key: :paste, char: text}} when is_binary(text) ->
        edit_buffer(state, event)
        put_pidx(state, 0)
        reset_history_cursor(state)
        draw.()
        cont.()

      # Scroll-back: PageUp/PageDown move the transcript window through
      # history; 0 follows the live tail. Mouse reporting stays disabled so
      # the host terminal can own drag selection and clipboard gestures.
      {_mode, %{type: :mouse, key: :wheel_up}} ->
        scroll_by(state, 3)
        draw.()
        cont.()

      {_mode, %{type: :mouse, key: :wheel_down}} ->
        scroll_by(state, -3)
        draw.()
        cont.()

      {_mode, %{key: :page_up}} ->
        scroll_by(state, 8)
        draw.()
        cont.()

      {_mode, %{key: :page_down}} ->
        scroll_by(state, -8)
        draw.()
        cont.()

      {_mode, _ignored} ->
        cont.()
    end
  end

  # Enter: a non-empty composer is a free-text answer, except explicit
  # cancel/decline text closes the active wonderTool. An empty composer submits
  # the wonderTool — every question's highlighted option in question order, in
  # one shot. Esc pauses (does not discard) so the user can talk to the main
  # session.
  defp handle_interaction_event(%{key: :enter}, result, output, state) do
    answer = String.trim(take_buffer(state))

    cond do
      answer != "" and wonder_active?(result) and cancel_answer?(answer) ->
        push_notification(state, "phase submitting - cancelling checkpoint")
        cancel = Map.get(result, :wonder_cancel)

        case cancel && cancel.(answer) do
          {:ok, _cancelled} ->
            push_notification(state, "phase accepted - checkpoint cancelled")
            log(output, "you> #{answer}")

          _other ->
            :ok
        end

      answer != "" and wonder_active?(result) ->
        push_notification(state, "phase submitting - sending free answer")
        submit = Map.get(result, :wonder_answer)

        case submit && submit.(wonder_free_text_payload(result, state, answer)) do
          {:ok, decision} ->
            push_notification(state, "phase accepted - answer captured")
            log(output, "you> #{Map.get(decision, :selected_label, answer)}")

          _other ->
            :ok
        end

      answer != "" and interview_active?(result) ->
        push_notification(state, "phase submitting - sending interview answer")
        send = Map.get(result, :interview_answer)

        case send && send.(answer) do
          {:ok, _text} ->
            push_notification(state, "phase accepted - answer captured")
            log(output, "you> #{answer}")

          _other ->
            :ok
        end

      answer != "" ->
        :ok

      wonder_active?(result) ->
        cond do
          any_free_answer_selected?(result, state) ->
            :ok

          wonder_needs_review?(result, state) ->
            put_wonder_nav(state, Map.put(wonder_nav(state), :review?, true))
            push_notification(state, "phase review - confirm answers before submit")

          true ->
            push_notification(state, "phase submitting - sending selected answers")
            submit = Map.get(result, :wonder_answer)
            selections = wonder_selections(result, state)

            case submit && submit.(selections) do
              {:ok, decision} ->
                push_notification(state, "phase accepted - answer captured")
                log(output, "you> #{Map.get(decision, :selected_label, "")}")

              _other ->
                :ok
            end
        end

      true ->
        :ok
    end
  end

  defp handle_interaction_event(%{key: :escape}, result, output, _state) do
    case Map.get(result, :wonder_pause) do
      pause when is_function(pause, 0) ->
        pause.()
        log(output, "-- interview paused (type to talk to main session)")

      _none ->
        :ok
    end
  end

  defp handle_interaction_event(_event, _result, _output, _state), do: :ok

  defp wonder_needs_review?(result, state) do
    detection = wonder_detection(result)
    qcount = detection |> wonder_questions() |> length()
    nav = wonder_nav(state)

    qcount > 1 and not Map.get(nav || %{}, :review?, false)
  end

  defp cancel_answer?(answer) when is_binary(answer) do
    answer
    |> String.downcase()
    |> String.trim()
    |> Kernel.in(["cancel", "decline", "/cancel"])
  end

  # Up/Dn are not textual input, so they must always let the user leave the
  # Free answer row. Left/Right still stay with the composer while free-typing.
  defp wonder_nav_event?(%{key: k}, _buffer, _result, _state) when k in [:up, :down],
    do: true

  # Bare 1-9 shortcuts only work while the concrete options are focused; once
  # the cursor is on the Free answer row, every character belongs to the answer
  # text.
  defp wonder_nav_event?(%{key: k}, buffer, result, state) when k in [:left, :right] do
    buffer == "" and not active_wonder_free_answer?(result, state)
  end

  defp wonder_nav_event?(%{key: :tab}, _buffer, _result, _state),
    do: true

  defp wonder_nav_event?(%{key: :char, char: " "}, buffer, result, state) do
    buffer == "" and not active_wonder_free_answer?(result, state) and
      multi_select?(active_wonder_question(result, state))
  end

  defp wonder_nav_event?(%{key: :char, char: c}, buffer, result, state)
       when is_binary(c),
       do: buffer == "" and c =~ ~r/^[1-9]$/ and not active_wonder_free_answer?(result, state)

  defp wonder_nav_event?(%{key: :char, char: c}, buffer, result, state)
       when c in ["h", "j", "k", "l"],
       do: buffer == "" and not active_wonder_free_answer?(result, state)

  defp wonder_nav_event?(_event, _buffer, _result, _state), do: false

  defp active_wonder_question(result, state) do
    detection = wonder_detection(result)
    questions = wonder_questions(detection)

    case questions do
      [] ->
        nil

      _questions ->
        nav = wonder_nav(state)
        qi = clamp_index(nav_qidx(nav), length(questions))
        Enum.at(questions, qi)
    end
  end

  defp active_wonder_free_answer?(result, state) do
    detection = wonder_detection(result)
    questions = wonder_questions(detection)

    case questions do
      [] ->
        false

      _questions ->
        nav = wonder_nav(state)
        qi = clamp_index(nav_qidx(nav), length(questions))
        question = Enum.at(questions, qi)
        opt_count = question |> Map.get(:options, []) |> length()
        current = if multi_select?(question), do: nav_cursor(nav, qi), else: nav_pick(nav, qi)

        current == opt_count
    end
  end

  defp wonder_free_text_payload(result, state, answer) do
    payload = %{"freeText" => answer}

    case active_wonder_question(result, state) do
      %{} = question ->
        case Map.get(question, :id) || Map.get(question, "id") do
          id when is_binary(id) and id != "" -> Map.put(payload, "questionId", id)
          _other -> payload
        end

      _none ->
        payload
    end
  end

  defp handle_wonder_nav(event, result, state) do
    detection = wonder_detection(result)

    case wonder_nav_after(detection, wonder_nav(state), event) do
      nil -> :ok
      nav -> put_wonder_nav(state, nav)
    end

    :ok
  end

  @doc false
  def wonder_nav_after(detection, nav, event) do
    questions = wonder_questions(detection)
    n = length(questions)

    if n > 0 do
      nav = nav || Ourocode.Terminal.InterviewPanel.default_nav(detection, nil)

      qi = clamp_index(nav_qidx(nav), n)
      question = Enum.at(questions, qi)
      opt_count = question |> Map.get(:options, []) |> length()
      multi? = multi_select?(question)
      current = if multi?, do: nav_cursor(nav, qi), else: nav_pick(nav, qi)

      apply_wonder_nav(event, nav, qi, n, opt_count, multi?, current)
    end
  end

  defp apply_wonder_nav(%{key: :tab}, nav, qi, n, _opts, _multi?, _current) do
    %{nav | qidx: rem(qi + 1, max(n, 1))}
  end

  defp apply_wonder_nav(%{key: :left}, nav, qi, n, _opts, _multi?, _current) do
    %{nav | qidx: Integer.mod(qi - 1, max(n, 1))}
  end

  defp apply_wonder_nav(%{key: :right}, nav, qi, n, _opts, _multi?, _current) do
    %{nav | qidx: rem(qi + 1, max(n, 1))}
  end

  defp apply_wonder_nav(%{key: :char, char: "h"}, nav, qi, n, opts, multi?, current) do
    apply_wonder_nav(%{key: :left}, nav, qi, n, opts, multi?, current)
  end

  defp apply_wonder_nav(%{key: :char, char: "l"}, nav, qi, n, opts, multi?, current) do
    apply_wonder_nav(%{key: :right}, nav, qi, n, opts, multi?, current)
  end

  defp apply_wonder_nav(%{key: :up}, nav, qi, _n, _opts, multi?, current) do
    put_cursor_or_pick(nav, qi, max(current - 1, 0), multi?)
  end

  defp apply_wonder_nav(%{key: :down}, nav, qi, _n, opt_count, multi?, current) do
    put_cursor_or_pick(nav, qi, min(current + 1, opt_count), multi?)
  end

  defp apply_wonder_nav(%{key: :char, char: "k"}, nav, qi, n, opts, multi?, current) do
    apply_wonder_nav(%{key: :up}, nav, qi, n, opts, multi?, current)
  end

  defp apply_wonder_nav(%{key: :char, char: "j"}, nav, qi, n, opts, multi?, current) do
    apply_wonder_nav(%{key: :down}, nav, qi, n, opts, multi?, current)
  end

  defp apply_wonder_nav(%{key: :char, char: " "}, nav, qi, _n, opt_count, true, _current) do
    cursor = nav_cursor(nav, qi)
    if cursor < opt_count, do: toggle_multi_pick(nav, qi, cursor), else: nav
  end

  defp apply_wonder_nav(%{key: :char, char: c}, nav, qi, _n, opt_count, multi?, _current)
       when c in ["1", "2", "3", "4", "5", "6", "7", "8", "9"] do
    idx = String.to_integer(c) - 1
    if idx < opt_count, do: put_cursor_or_pick(nav, qi, idx, multi?), else: nav
  end

  defp apply_wonder_nav(_event, nav, _qi, _n, _opts, _multi?, _current), do: nav

  defp put_cursor_or_pick(nav, qi, idx, true) do
    %{nav | cursors: Map.put(Map.get(nav, :cursors, %{}), qi, idx)}
  end

  defp put_cursor_or_pick(nav, qi, idx, false), do: put_pick(nav, qi, idx)

  defp put_pick(nav, qi, idx) do
    %{nav | picks: Map.put(Map.get(nav, :picks, %{}), qi, idx)}
  end

  defp toggle_multi_pick(nav, qi, idx) do
    picks = Map.get(nav, :picks, %{})
    selected = Map.get(picks, qi, MapSet.new())

    selected =
      if MapSet.member?(selected, idx),
        do: MapSet.delete(selected, idx),
        else: MapSet.put(selected, idx)

    %{nav | picks: Map.put(picks, qi, selected)}
  end

  # 1-based option index per question, in question order — the payload
  # LoopBindings.answer_wonder expects (a single-element list for the
  # always-1-question interview path collapses to the legacy single answer).
  defp wonder_selections(result, state) do
    questions = result |> wonder_detection() |> wonder_questions()
    nav = wonder_nav(state)

    questions
    |> Enum.with_index()
    |> Enum.map(fn {q, qi} ->
      if multi_select?(q) do
        nav_multi_pick(nav, qi)
        |> MapSet.to_list()
        |> Enum.sort()
        |> Enum.map(&(&1 + 1))
      else
        nav_pick(nav, qi) + 1
      end
    end)
  end

  defp any_free_answer_selected?(result, state) do
    questions = result |> wonder_detection() |> wonder_questions()
    nav = wonder_nav(state)

    Enum.with_index(questions)
    |> Enum.any?(fn {question, qi} ->
      opt_count = question |> Map.get(:options, []) |> length()
      current = if multi_select?(question), do: nav_cursor(nav, qi), else: nav_pick(nav, qi)
      current == opt_count
    end)
  end

  defp close_palette(state) do
    put_mode(state, :normal)
    _ = take_buffer(state)
    put_pidx(state, 0)
  end

  defp palette_choice(state) do
    entries = Palette.filter(Palette.entries(), buffer(state))

    case Palette.selected(entries, pidx(state)) do
      %{slash: slash} -> slash
      _ -> String.trim(buffer(state))
    end
  end

  defp choose_model(result, output, state, cols, rows) do
    models = Catalog.selectable(Catalog.list())
    sel = Enum.at(models, clamp_index(pidx(state), length(models)))
    close_palette(state)

    cond do
      sel == nil ->
        redraw(result, output, state, "", cols, rows)

      Model.ready?(sel) ->
        put_model_id(state, sel.id)
        log(output, "model: #{sel.label}")
        redraw(result, output, state, "", cols, rows)

      sel.id == :codex ->
        put_model_id(state, :codex)
        do_login(result, output, state, cols, rows)

      true ->
        log(output, "#{sel.label} is not ready.")
        redraw(result, output, state, "", cols, rows)
    end
  end

  # --- main session: auth + LLM -------------------------------------------

  defp handle_enter("", _result, _output, _state, _cols, _rows), do: :continue

  defp handle_enter("/login", result, output, state, cols, rows) do
    do_login(result, output, state, cols, rows)
    :continue
  end

  defp handle_enter("/logout", result, output, state, cols, rows) do
    Codex.clear()
    log(output, "Signed out of ChatGPT.")
    redraw(result, output, state, "", cols, rows)
    :continue
  end

  defp handle_enter("/clear", result, output, state, cols, rows) do
    clear_captured_output(output)
    redraw(result, output, state, "", cols, rows)
    :continue
  end

  defp handle_enter("/answer " <> answer, result, output, state, _cols, _rows) do
    answer = String.trim(answer)

    cond do
      answer == "" ->
        log(output, "usage: /answer <interview answer>")

      interview_active?(result) ->
        send = Map.get(result, :interview_answer)

        case send && send.(answer) do
          {:ok, _text} -> log(output, "you> #{answer}")
          _other -> log(output, "No active interview answer target.")
        end

      wonder_active?(result) ->
        submit = Map.get(result, :wonder_answer)

        case submit && submit.(wonder_free_text_payload(result, state, answer)) do
          {:ok, decision} -> log(output, "you> #{Map.get(decision, :selected_label, answer)}")
          _other -> log(output, "No active wonder answer target.")
        end

      true ->
        log(output, "No active interview answer target.")
    end

    :continue
  end

  defp handle_enter("/exit", _r, _o, _s, _c, _ro), do: :exit
  defp handle_enter("/quit", _r, _o, _s, _c, _ro), do: :exit

  defp handle_enter(m, result, output, state, cols, rows)
       when m in ["/model", "/models"] do
    put_mode(state, :model)
    put_pidx(state, 0)
    redraw(result, output, state, "", cols, rows)
    :continue
  end

  defp handle_enter("/" <> _ = line, _r, _o, _s, _c, _ro), do: {:submit, line}

  defp handle_enter("ooo" <> _ = line, result, output, state, cols, rows) do
    redraw(result, output, state, "", cols, rows)
    {:submit, line}
  end

  defp handle_enter(prompt, result, output, state, cols, rows) do
    chat(prompt, result, output, state, cols, rows)
    :continue
  end

  defp do_login(result, output, state, cols, rows) do
    case Codex.start_device_login() do
      {:ok, dev} ->
        put_login(state, %{code: dev.user_code, url: dev.verification_uri})
        redraw(result, output, state, "", cols, rows)
        poll_login(dev, 0, result, output, state, cols, rows)

      {:error, reason} ->
        log(output, "Login could not start: #{inspect(reason)}")
        redraw(result, output, state, "", cols, rows)
    end
  end

  @max_login_polls 80

  defp poll_login(_dev, polls, result, output, state, cols, rows)
       when polls >= @max_login_polls do
    put_login(state, nil)
    log(output, "Login timed out. Run /login to try again.")
    redraw(result, output, state, "", cols, rows)
  end

  defp poll_login(dev, polls, result, output, state, cols, rows) do
    deadline = System.monotonic_time(:millisecond) + dev.interval_ms

    case wait_or_cancel(state, deadline) do
      :cancel ->
        put_login(state, nil)
        log(output, "Login cancelled.")
        redraw(result, output, state, "", cols, rows)

      :timeout ->
        case Codex.poll_device_login(dev) do
          {:ok, tokens} ->
            put_login(state, nil)
            put_model_id(state, :codex)
            who = tokens.email || tokens.account_id || "your ChatGPT account"
            log(output, "Signed in as #{who}. model: codex (ChatGPT) - ask anything.")
            redraw(result, output, state, "", cols, rows)

          :pending ->
            redraw(result, output, state, "", cols, rows)
            poll_login(dev, polls + 1, result, output, state, cols, rows)

          {:error, reason} ->
            put_login(state, nil)
            log(output, "Login failed: #{inspect(reason)}")
            redraw(result, output, state, "", cols, rows)
        end
    end
  end

  # Sleeps until `deadline`, but stays responsive: a Ctrl-C / Esc keystroke
  # from the helper aborts the login instead of the loop blocking the whole
  # input path (which made the program impossible to quit from the card).
  defp wait_or_cancel(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      port = port(state)

      receive do
        {^port, {:data, data}} ->
          if String.contains?(data, <<3>>) or String.contains?(data, <<27>>),
            do: :cancel,
            else: wait_or_cancel(state, deadline)

        {^port, {:exit_status, _}} ->
          :cancel
      after
        remaining -> :timeout
      end
    end
  end

  defp chat(prompt, result, output, state, cols, rows) do
    model = active_model(state)

    cond do
      model == nil ->
        log(output, "you> #{prompt}")
        log(output, "No model available. /model to pick one, /login for ChatGPT.")
        redraw(result, output, state, "", cols, rows)

      Model.needs_auth?(model) ->
        log(output, "you> #{prompt}")
        log(output, "#{model.label} needs sign-in. /login for ChatGPT, or /model.")
        redraw(result, output, state, "", cols, rows)

      true ->
        log(output, "you> #{prompt}")
        IO.write(output, "ourocode> ")
        set_streaming(state, true)
        redraw(result, output, state, "", cols, rows)

        on_chunk = fn chunk ->
          IO.write(output, chunk)
          redraw(result, output, state, "", cols, rows)
        end

        model_prompt = maybe_paused_interview_prompt(result, prompt)

        case Model.stream(model, model_prompt, [session_id: session_id(result)], on_chunk) do
          {:ok, full} ->
            IO.write(output, "\n")
            maybe_handoff_paused_interview_answer(result, output, full)

          {:error, :not_signed_in} ->
            log(output, "\nNot connected. /login for ChatGPT.")

          {:error, reason} ->
            log(output, "\n#{model.label} error: #{inspect(reason)}")
        end

        set_streaming(state, false)
        redraw(result, output, state, "", cols, rows)
    end
  end

  defp maybe_paused_interview_prompt(result, prompt) do
    if paused?(result) and (interview_active?(result) or wonder_active?(result)) do
      """
      You are the main ourocode session. An interview checkpoint is paused so
      the user can discuss it with you before answering.

      Pending interview question:
      #{paused_interview_question(result)}

      User message:
      #{prompt}

      Reply normally. If, and only if, your reply is ready to be submitted as
      the final answer to the pending interview question, include a final line:
      INTERVIEW_ANSWER: <concise answer to submit>
      Do not include that line for clarifications, translations, explanations,
      or ordinary discussion.
      """
    else
      prompt
    end
  end

  defp paused_interview_question(result) do
    cond do
      detection = wonder_detection(result) ->
        detection
        |> wonder_questions()
        |> List.first()
        |> case do
          %{} = question -> md_text(Map.get(question, :question, ""))
          _none -> "unknown"
        end

      interview = interview_state(result) ->
        md_text(Map.get(interview, :question, "unknown"))

      true ->
        "unknown"
    end
  end

  defp maybe_handoff_paused_interview_answer(result, output, full) do
    with true <- paused?(result),
         true <- interview_active?(result) or wonder_active?(result),
         answer when is_binary(answer) <- extract_interview_answer(full),
         send when is_function(send, 1) <- Map.get(result, :interview_answer),
         {:ok, _text} <- send.(answer) do
      log(output, "-- interview answered from main session")
    else
      _other -> :ok
    end
  end

  defp extract_interview_answer(full) when is_binary(full) do
    full
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*INTERVIEW_ANSWER:\s*(.+?)\s*$/u, line) do
        [_, answer] -> String.trim(answer)
        _none -> nil
      end
    end)
  end

  defp extract_interview_answer(_full), do: nil

  defp log(output, text), do: IO.puts(output, text)

  defp clear_captured_output(output) do
    StringIO.flush(output)
    :ok
  rescue
    _exception -> :ok
  end

  defp session_id(result) do
    get_in(result, [:runtime, :session_id]) || get_in(result, [:context, :runtime_session_id]) ||
      "ourocode-main"
  end

  defp active_model(state) do
    now = System.monotonic_time(:millisecond)

    Agent.get_and_update(state, fn current ->
      id = current.model_id

      case current.model_cache do
        %{id: ^id, expires_at: expires_at, model: %Model{} = model} when expires_at > now ->
          {model, current}

        _stale ->
          models = Catalog.list()
          model = Catalog.fetch(models, id) || Catalog.default()

          {model,
           %{
             current
             | model_cache: %{id: id, expires_at: now + @model_cache_ttl_ms, model: model}
           }}
      end
    end)
  end

  defp auth_label(state) do
    model = active_model(state)

    case model && model.status do
      :ready -> {"model: #{model.label}", :ok}
      {:needs_auth, hint} -> {"model: #{model.label}  #{hint}", :dim}
      _ -> {"no model  -  /model", :dim}
    end
  end

  # --- rendering -----------------------------------------------------------

  @doc """
  Builds the composed frame as plain text rows (no ANSI), for snapshot tests
  and previews. `frame` is the SSoT text projection from `ShellRenderer`.
  """
  @spec frame_lines(String.t(), [String.t()], String.t(), pos_integer(), pos_integer(), map()) ::
          [String.t()]
  def frame_lines(frame, activity, prompt_buffer, columns, rows, opts \\ %{})
      when is_binary(frame) and is_list(activity) and is_binary(prompt_buffer) do
    frame
    |> parse_sections()
    |> then(&compose(columns, rows, &1, activity, prompt_buffer, opts))
    |> Screen.to_lines()
  end

  defp redraw(result, output, state, prompt_buffer, columns, rows) do
    bump_tick(state)
    sections = parse_sections(ShellRenderer.render_initial_frame(live_result(result)))
    activity = activity_lines(output)

    nav = sync_wonder_nav(state, result)

    opts =
      view_opts(state)
      |> Map.put(:interview_block, interview_block_lines(result, nav, tick(state)))
      |> Map.put(:interview_reasoning, interview_reasoning_lines(result, tick(state)))
      |> Map.put(:mcp_activity, mcp_activity_lines(result))
      |> Map.put(:wonder_focus, wonder_active?(result) and not paused?(result))
      |> Map.put(:interview_paused, paused?(result))

    screen = compose(columns, rows, sections, activity, prompt_buffer, opts)

    {iodata, screen} = Screen.diff(prev_screen(state), screen)
    put_prev_screen(state, screen)
    tty_write(state, iodata)
    cursor_to_prompt(state, rows, columns, prompt_buffer)
  end

  # Projects the live runtime pane snapshot (parent/child MCP panes folded by
  # the loop bindings) into the SSoT frame so streaming is visible on the
  # renderer's own cadence. Falls back to the static result if no live source
  # is attached (non-interactive, no runtime), keeping snapshot tests stable.
  defp live_result(%{pane_snapshot: snapshot} = result) when is_function(snapshot, 0) do
    %{runtime: %{parent_panes: parent, child_panes: child}} = snapshot.()

    Map.put(
      result,
      :parent_child_hierarchy,
      Ourocode.Dashboard.Layout.parent_child_hierarchy(parent, child)
    )
  rescue
    _exception -> result
  end

  defp live_result(result), do: result

  # Full live interaction snapshot (wonderTool checkpoint + interview reasoning
  # + paused flag) from the loop bindings. nil when no live source is attached.
  defp interaction_snapshot(%{pane_snapshot: snapshot}) when is_function(snapshot, 0) do
    snapshot.()
  rescue
    _exception -> nil
  end

  defp interaction_snapshot(_result), do: nil

  defp wonder_detection(result) do
    case interaction_snapshot(result) do
      %{wonder_tool: %{} = detection} -> detection
      _none -> nil
    end
  end

  defp interview_state(result) do
    case interaction_snapshot(result) do
      %{interview: %{} = interview} -> interview
      _none -> nil
    end
  end

  defp paused?(result) do
    case interaction_snapshot(result) do
      %{paused: true} -> true
      _other -> false
    end
  end

  # The sticky session: set the moment `ooo interview` is dispatched and held
  # until the interview actually ends (LoopBindings owns the lifecycle). This
  # is what keeps the UI in "interview mode" between questions and across
  # agent turns, independent of whether a question is pending right now.
  defp interview_session(result) do
    case interaction_snapshot(result) do
      %{interview_session: %{} = session} -> session
      _none -> nil
    end
  end

  defp wonder_active?(result), do: wonder_detection(result) != nil
  defp interview_active?(result), do: interview_state(result) != nil

  # Only an *unpaused* checkpoint owns answer keys; paused lets the user talk
  # to the main session normally (the skill's "Esc to pause" flow).
  defp interaction_capturing?(result) do
    (wonder_active?(result) or interview_active?(result)) and not paused?(result)
  end

  # The prominent left-column INTERVIEW block uses an accent rail, marker, and
  # emphasized question with dim options/answer text. nil when nothing is
  # pending. `nav` is the live selection cursor (see wonder_nav/1).
  defp interview_block_lines(result, nav, tick) do
    cond do
      detection = wonder_detection(result) ->
        # The picker owns this space while active. Long MCP questions can
        # otherwise push the selectable options below the block cap, making
        # the checkpoint look like it never rendered.
        case wonder_picker_lines(detection, nav) do
          [] ->
            nil

          picker ->
            {wonder_marker(result), picker, wonder_pick_hint(result, wonder_qcount(detection))}
        end

      _interview = interview_state(result) ->
        # Plain question / waiting: the color-coded conversation (the latest
        # MCP turn IS the open question, kept in role color — not re-printed
        # plain) plus an animated activity line so it never looks frozen and
        # the operator sees the main session working.
        lines = dialogue_rows(result, false) ++ interview_status_rows(result, tick)
        {wonder_marker(result), lines, wonder_hint(result)}

      session = interview_session(result) ->
        label = Map.get(session, :label, "ooo interview")
        spinner = if paused?(result), do: [], else: [{working_line(tick, nil), :dim}]
        {wonder_marker(result), [label | spinner], interview_session_hint(result)}

      true ->
        nil
    end
  rescue
    _exception -> nil
  end

  # The shared conversation tail, color-coded by speaker so the dialectic
  # reads at a glance: MCP (the question generator) amber, MAIN (the
  # answerer/main session's resolved turn) green, YOU (your judgment) bold.
  # `drop_trailing_mcp?` hides the open question here when the picker below
  # already renders it. Returned as {text, style} rows the block paints
  # verbatim (no '> ' / strong inference).
  @doc false
  @spec dialogue_rows(map(), boolean()) :: [{String.t(), atom()} | :rule]
  def dialogue_rows(result, drop_trailing_mcp?),
    do: Ourocode.Terminal.InterviewPanel.dialogue_rows(result, drop_trailing_mcp?)

  # The LEFT-block activity under a plain question: a single animated line
  # carrying only the latest *clean* router trace — never the raw streamed
  # model text — so the main session's work is visible without leaking the
  # ASK_USER directive protocol. Public for snapshot tests.
  @doc false
  @spec interview_working_lines(map(), integer()) :: [String.t()]
  def interview_working_lines(result, tick),
    do: Ourocode.Terminal.InterviewPanel.interview_working_lines(result, tick)

  defp interview_status_rows(result, tick) do
    status = interview_working_lines(result, tick)

    cond do
      status == [] ->
        []

      dialogue_rows(result, false) == [] ->
        Enum.map(status, &{&1, :dim})

      true ->
        [:rule | Enum.map(status, &{&1, :dim})]
    end
  end

  # The active question's selection block: header (with "i/n" only when
  # multi), the question text, then each option with a ">" cursor on the
  # highlighted row. Public (snapshot tests) and deterministic for a given
  # detection + nav; [] when there is nothing to render.
  @doc false
  @spec wonder_picker_lines(map(), map() | nil) :: [String.t()]
  def wonder_picker_lines(detection, nav),
    do: Ourocode.Terminal.InterviewPanel.wonder_picker_lines(detection, nav)

  # Initializes / carries the selection cursor for the live checkpoint and
  # resets it when a new checkpoint (different request_id) arrives. Returns the
  # nav for the renderer; nil clears it when no checkpoint is pending.
  defp sync_wonder_nav(state, result) do
    case wonder_detection(result) do
      nil ->
        put_wonder_nav(state, nil)
        nil

      detection ->
        nav = wonder_nav(state)
        nav = Ourocode.Terminal.InterviewPanel.default_nav(detection, nav)

        put_wonder_nav(state, nav)
        nav
    end
  rescue
    _exception -> nil
  end

  # While the session is live but no question is on the wire, the block is a
  # calm presence marker — replies still go to the main session (the block
  # does not capture keys), and it stays until the interview ends.
  defp interview_session_hint(result) do
    if paused?(result),
      do: "paused   type to talk to main   /answer <answer> submits to interview",
      else: "running   the main session is handling this   stays until it ends"
  end

  defp wonder_marker(result) do
    if paused?(result), do: "INTERVIEW (paused)", else: "INTERVIEW"
  end

  defp wonder_hint(result) do
    cond do
      paused?(result) -> "type to talk to main session   answers resume the interview"
      wonder_active?(result) -> "1-9 select   type free answer   /cancel decline   Esc pause"
      true -> "type your answer + Enter   Esc pause"
    end
  end

  defp wonder_pick_hint(result, qcount) do
    cond do
      paused?(result) ->
        "type to talk to main   /answer <answer> submits to interview"

      qcount > 1 ->
        "Up/Dn pick   Tab next question   Free answer row   Enter submit all   Esc pause"

      true ->
        "Up/Dn pick   1-9 shortcut   Free answer row   Enter submit   Esc pause"
    end
  end

  # Right-column section: MCP-internal only — what the interview engine puts
  # on the wire (ambiguity score, breakdown, milestone, seed-ready, server
  # status, session). The answerer/router reasoning is the MAIN SESSION's
  # work and lives in the LEFT block (`block_reasoning_tail/1`), never here.
  # Public for snapshot tests.
  @doc false
  def interview_reasoning_lines(result, tick \\ nil) do
    Ourocode.Terminal.InterviewPanel.interview_reasoning_lines(result, tick)
  end

  @doc false
  def mcp_activity_lines(result) do
    Ourocode.Terminal.InterviewPanel.mcp_activity_lines(result)
  end

  defp wonder_qcount(detection), do: Ourocode.Terminal.InterviewPanel.question_count(detection)

  defp wonder_questions(detection),
    do: Ourocode.Terminal.InterviewPanel.wonder_questions(detection)

  defp nav_qidx(nav), do: Ourocode.Terminal.InterviewPanel.nav_qidx(nav)
  defp nav_cursor(nav, qi), do: Ourocode.Terminal.InterviewPanel.nav_cursor(nav, qi)
  defp nav_pick(nav, qi), do: Ourocode.Terminal.InterviewPanel.nav_pick(nav, qi)
  defp nav_multi_pick(nav, qi), do: Ourocode.Terminal.InterviewPanel.nav_multi_pick(nav, qi)
  defp multi_select?(question), do: Ourocode.Terminal.InterviewPanel.multi_select?(question)
  defp working_line(tick, trace), do: Ourocode.Terminal.InterviewPanel.working_line(tick, trace)
  defp md_text(text), do: Ourocode.Terminal.InterviewPanel.md_text(text)

  defp view_opts(state) do
    mode = get_mode(state)

    %{
      mode: mode,
      login: login_state(state),
      streaming: streaming?(state),
      key_help: key_help?(state),
      tick: tick(state),
      scroll: scroll_off(state),
      pidx: pidx(state),
      auth: auth_label(state),
      notifications: notifications(state),
      ooo_commands:
        if mode == :normal and Suggestions.ooo_prompt?(buffer(state)) do
          cached_ooo_commands(state)
        else
          nil
        end,
      palette:
        if mode == :palette do
          entries = Palette.filter(Palette.entries(), buffer(state))
          %{entries: entries, index: Palette.clamp(pidx(state), length(entries))}
        else
          nil
        end,
      model:
        if mode == :model do
          models = Catalog.selectable(Catalog.list())
          %{models: models, index: clamp_index(pidx(state), length(models))}
        else
          nil
        end,
      file_mentions: file_mention_suggestions(state, mode, false)
    }
  end

  # Modular wrap: pidx grows unbounded as arrows are pressed, so it must map
  # continuously onto 0..n-1 (a plain clamp froze the selection after one
  # full cycle).
  defp clamp_index(_i, 0), do: 0
  defp clamp_index(i, n), do: Integer.mod(i, n)

  @ooo_cache_ttl_ms 30_000

  defp cached_ooo_commands(state) do
    now = System.monotonic_time(:millisecond)

    Agent.get_and_update(state, fn s ->
      fresh? =
        is_list(s.ooo_cache) and is_integer(Map.get(s, :ooo_cache_loaded_ms)) and
          now - s.ooo_cache_loaded_ms < @ooo_cache_ttl_ms

      commands = if fresh?, do: s.ooo_cache, else: Suggestions.build_ooo_commands(test_run?())
      {commands, %{s | ooo_cache: commands, ooo_cache_loaded_ms: now}}
    end)
  end

  defp ooo_suggesting?(state) do
    prompt_buffer = buffer(state)

    Suggestions.ooo_prompt?(prompt_buffer) and
      Suggestions.ooo_suggestions(prompt_buffer, :normal, false, cached_ooo_commands(state)) != []
  end

  defp file_mention_suggestions(state, :normal, false) do
    case active_file_mention_query(buffer(state), cursor(state)) do
      nil ->
        []

      query ->
        state
        |> file_cache()
        |> Enum.map(fn path -> {path, {path, Suggestions.file_label(path)}} end)
        |> Ourocode.Terminal.Fuzzy.rank(query, limit: 8)
    end
  end

  defp file_mention_suggestions(_state, _mode, _wonder_focus), do: []

  defp file_mention_suggesting?(state) do
    file_mention_suggestions(state, get_mode(state), false) != []
  end

  defp insert_file_mention_choice(state) do
    suggestions = file_mention_suggestions(state, get_mode(state), false)
    clamped = Palette.clamp(pidx(state), length(suggestions))

    case Enum.at(suggestions, clamped) do
      {path, _label} ->
        Agent.update(state, fn s ->
          {buffer, cursor} = Suggestions.replace_active_file_mention(s.buffer, s.cursor, path)
          %{s | buffer: buffer, cursor: cursor}
        end)

      _none ->
        :ok
    end
  end

  @doc false
  def active_file_mention_query(prompt_buffer, cursor) when is_binary(prompt_buffer) do
    Suggestions.active_file_mention_query(prompt_buffer, cursor)
  end

  defp ooo_choice(prompt_buffer, index, state) do
    Suggestions.ooo_choice(prompt_buffer, index, cached_ooo_commands(state))
  end

  defp compose(columns, rows, sections, activity, prompt_buffer, opts) do
    Ourocode.Terminal.Renderer.compose(columns, rows, sections, activity, prompt_buffer, opts)
  end

  defp parse_sections(frame), do: Ourocode.Terminal.Renderer.parse_sections(frame)

  defp activity_lines(output) do
    {_input, captured} = StringIO.contents(output)

    String.split(captured, "\n", trim: true)
  end

  @doc false
  @spec wrap_text(String.t(), pos_integer()) :: [String.t()]
  def wrap_text(text, width), do: Ourocode.Terminal.Renderer.wrap_text(text, width)

  defp cursor_to_prompt(state, rows, columns, prompt_buffer) do
    height = max(rows, @min_height)
    width = max(columns, @min_width)
    prefix = prompt_buffer |> String.graphemes() |> Enum.take(cursor(state)) |> Enum.join()
    # Composer input sits at row `height - 2` (0-indexed); ANSI is 1-indexed.
    ansi_row = height - 1
    ansi_col = min(@body + 1 + Screen.text_width(prefix), width)
    tty_write(state, "\e[#{ansi_row};#{ansi_col}H\e[?25h")
  end

  # --- terminal control (native helper) ------------------------------------

  # An escript cannot reliably raw-mode its controlling terminal (`stty` via
  # :os.cmd has no usable ctty), so a tiny native helper owns the tty: it
  # sets termios raw, reports size via TIOCGWINSZ, streams keystrokes to its
  # stdout, and writes frames from its stdin to the tty. We talk to it over
  # an OS pipe (a Port), which is reliable. This is the seed's replaceable
  # native frontend piece; the Elixir runtime stays the source of truth.

  @doc "Absolute path of the built tty helper, or nil if it is not present."
  @spec helper_path() :: String.t() | nil
  def helper_path do
    [
      System.get_env("OUROCODE_TTY"),
      Path.join(File.cwd!(), "rust/ourocode_ipc/target/release/ourocode_tty"),
      Path.join(File.cwd!(), "bin/ourocode_tty")
    ]
    |> Enum.find(fn p -> is_binary(p) and File.exists?(p) end)
  end

  defp start_driver(state) do
    case helper_path() do
      nil ->
        :error

      path ->
        # `:nouse_stdio` leaves the child's fds 0/1/2 inherited from the BEAM
        # (the real terminal) and moves this protocol channel to fds 3/4, so
        # the helper can raw-mode the actual terminal without a ctty.
        port =
          Port.open({:spawn_executable, String.to_charlist(path)}, [
            :binary,
            :exit_status,
            :nouse_stdio,
            :hide
          ])

        case read_header(port, "") do
          {:ok, cols, rows, rest} ->
            put_port(state, port)
            put_size(state, {cols, rows})
            put_inbuf(state, rest)
            # Keep mouse reporting off: the host terminal should own drag
            # selection and clipboard gestures while ourocode owns keyboard input.
            tty_write(state, terminal_enter_sequence())
            :ok

          :error ->
            safe_port_close(port)
            :error
        end
    end
  end

  # First stdout line from the helper is "<cols> <rows>\n"; anything after it
  # in the same packet is the start of the key byte stream.
  defp read_header(port, acc) do
    receive do
      {^port, {:data, data}} ->
        buf = acc <> data

        case :binary.split(buf, "\n") do
          [line, rest] ->
            case line |> String.split() |> Enum.map(&Integer.parse/1) do
              [{cols, _}, {rows, _}] when cols > 0 and rows > 0 ->
                {:ok, cols, rows, rest}

              _ ->
                :error
            end

          [_partial] ->
            read_header(port, buf)
        end

      {^port, {:exit_status, _}} ->
        :error
    after
      5_000 -> :error
    end
  end

  defp stop_driver(state) do
    case port(state) do
      nil ->
        :ok

      port ->
        tty_write(state, terminal_exit_sequence())
        safe_port_close(port)
    end
  end

  @doc false
  def terminal_enter_sequence, do: "\e[?1049h\e[?25l\e[2J\e[H"

  @doc false
  def terminal_exit_sequence, do: "\e[?25h\e[?1049l"

  defp safe_port_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp tty_write(state, iodata) do
    case port(state) do
      nil -> :ok
      port -> Port.command(port, IO.iodata_to_binary(iodata))
    end
  end

  # Returns the next raw input chunk: buffered remainder first, otherwise the
  # next packet from the helper. `:eof` when the helper exits.
  # ~0.5s wake so streamed MCP events (folded into live pane state off-loop)
  # repaint on a steady cadence without waiting for a keystroke, keeping the
  # first-visible-event budget well under the 5s ceiling.
  @poll_ms 500

  defp next_chunk(state) do
    case take_inbuf(state) do
      "" ->
        port = port(state)

        receive do
          {^port, {:data, data}} ->
            {:ok, data}

          {^port, {:exit_status, _}} ->
            :eof

          {:file_cache_ready, files} when is_list(files) ->
            put_file_cache(state, files)
            :tick
        after
          @poll_ms -> :tick
        end

      buffered ->
        {:ok, buffered}
    end
  end

  defp tty? do
    match?({:ok, _}, :io.columns())
  end

  defp refresh_size(state) do
    case {:io.columns(), :io.rows()} do
      {{:ok, cols}, {:ok, rows}} when cols > 0 and rows > 0 ->
        size = {cols, rows}
        put_size(state, size)
        size

      _other ->
        size(state)
    end
  rescue
    _exception -> size(state)
  end

  defp stdio_device?(:stdio), do: true
  defp stdio_device?(:standard_io), do: true
  defp stdio_device?(_other), do: false

  # --- driver state --------------------------------------------------------

  defp start_state do
    {:ok, pid} =
      Agent.start_link(fn ->
        draft = PromptStore.load_draft()

        %{
          buffer: draft,
          cursor: String.length(draft),
          leftover: "",
          prev_screen: nil,
          port: nil,
          inbuf: "",
          mode: :normal,
          pidx: 0,
          login: nil,
          streaming: false,
          key_help: false,
          tick: 0,
          size: {120, 40},
          model_id: nil,
          model_cache: nil,
          scroll: 0,
          wonder_nav: nil,
          history: PromptStore.load_history(),
          history_index: 0,
          history_draft: nil,
          file_cache: nil,
          ooo_cache: nil,
          ooo_cache_loaded_ms: nil,
          kill_ring: [],
          kill_index: 0,
          last_edit_was_kill: false,
          last_yank: nil,
          esc_armed_until: nil,
          notifications: []
        }
      end)

    pid
  end

  # Ephemeral selection cursor for the active wonderTool checkpoint (pure view
  # state — the runtime SSoT stays in LoopBindings). `nil` when no checkpoint.
  # When active: %{req_id, qidx, picks: %{question_index => option_index}}.
  defp wonder_nav(state), do: Agent.get(state, & &1.wonder_nav)
  defp put_wonder_nav(state, nav), do: Agent.update(state, &%{&1 | wonder_nav: nav})

  # Transcript scroll-back offset in rows: 0 follows the tail (latest), a
  # positive value scrolls up into history. Clamped by the renderer against
  # available history so it can never run past the buffer.
  defp scroll_off(state), do: Agent.get(state, & &1.scroll)

  defp put_scroll(state, value) do
    Agent.update(state, &%{&1 | scroll: max(value, 0)})
  end

  defp scroll_by(state, delta), do: put_scroll(state, scroll_off(state) + delta)

  defp put_model_id(state, id), do: Agent.update(state, &%{&1 | model_id: id, model_cache: nil})
  defp size(state), do: Agent.get(state, & &1.size)
  defp put_size(state, wh), do: Agent.update(state, &%{&1 | size: wh})
  defp get_mode(state), do: Agent.get(state, & &1.mode)
  defp put_mode(state, mode), do: Agent.update(state, &%{&1 | mode: mode})
  defp pidx(state), do: Agent.get(state, & &1.pidx)
  defp put_pidx(state, index), do: Agent.update(state, &%{&1 | pidx: index})
  defp login_state(state), do: Agent.get(state, & &1.login)
  defp put_login(state, login), do: Agent.update(state, &%{&1 | login: login, model_cache: nil})
  defp streaming?(state), do: Agent.get(state, & &1.streaming)
  defp set_streaming(state, on), do: Agent.update(state, &%{&1 | streaming: on})
  defp key_help?(state), do: Agent.get(state, & &1.key_help)
  defp toggle_key_help(state), do: Agent.update(state, &%{&1 | key_help: not &1.key_help})
  defp tick(state), do: Agent.get(state, & &1.tick)
  defp bump_tick(state), do: Agent.update(state, &%{&1 | tick: &1.tick + 1})

  defp file_cache(state) do
    case Agent.get(state, & &1.file_cache) do
      files when is_list(files) ->
        files

      :loading ->
        []

      _none ->
        start_file_cache(state)
        []
    end
  end

  defp start_file_cache(state) do
    owner = self()

    started? =
      Agent.get_and_update(state, fn s ->
        case s.file_cache do
          nil -> {true, %{s | file_cache: :loading}}
          _other -> {false, s}
        end
      end)

    if started? do
      _ =
        Task.start(fn ->
          send(owner, {:file_cache_ready, discover_files()})
        end)
    end

    :ok
  end

  defp put_file_cache(state, files) when is_list(files) do
    Agent.update(state, &%{&1 | file_cache: files})
  end

  defp discover_files do
    case System.find_executable("rg") do
      nil ->
        []

      _rg ->
        case System.cmd("rg", ["--files"], cd: File.cwd!(), stderr_to_stdout: true) do
          {out, 0} ->
            out
            |> String.split("\n", trim: true)
            |> Enum.reject(&ignored_file_path?/1)
            |> Enum.take(1_000)

          _other ->
            []
        end
    end
  rescue
    _exception -> []
  end

  defp ignored_file_path?(path) do
    String.starts_with?(path, ["_build/", "deps/", ".git/"]) or
      String.contains?(path, ["/_build/", "/deps/", "/.git/"])
  end

  defp notifications(state) do
    now = System.monotonic_time(:millisecond)

    Agent.get_and_update(state, fn s ->
      active =
        s.notifications
        |> Enum.filter(fn {_text, until_ms} -> until_ms > now end)
        |> Enum.take(3)

      {Enum.map(active, fn {text, _until_ms} -> text end), %{s | notifications: active}}
    end)
  end

  defp push_notification(state, text, ttl_ms \\ 1_500) do
    until_ms = System.monotonic_time(:millisecond) + ttl_ms

    Agent.update(state, fn s ->
      %{s | notifications: [{text, until_ms} | s.notifications] |> Enum.take(3)}
    end)
  end

  defp port(state), do: Agent.get(state, & &1.port)
  defp put_port(state, port), do: Agent.update(state, &%{&1 | port: port})
  defp put_inbuf(state, bytes), do: Agent.update(state, &%{&1 | inbuf: bytes})
  defp take_inbuf(state), do: Agent.get_and_update(state, &{&1.inbuf, %{&1 | inbuf: ""}})

  defp buffer(state), do: Agent.get(state, & &1.buffer)
  defp cursor(state), do: Agent.get(state, & &1.cursor)

  defp edit_buffer(state, event) do
    Agent.update(state, fn s ->
      s = Ourocode.Terminal.InputEditor.edit_state(s, event)
      PromptStore.save_draft(s.buffer)
      s
    end)
  end

  @double_press_ms 800

  defp handle_escape_clear(state) do
    now = System.monotonic_time(:millisecond)

    Agent.update(state, fn s ->
      cond do
        s.buffer == "" ->
          %{s | esc_armed_until: nil, notifications: []}

        is_integer(s.esc_armed_until) and s.esc_armed_until >= now ->
          %{
            s
            | buffer: "",
              cursor: 0,
              history_index: 0,
              history_draft: nil,
              esc_armed_until: nil,
              notifications: [{"input cleared", now + 1_000} | s.notifications] |> Enum.take(3)
          }

        true ->
          %{
            s
            | esc_armed_until: now + @double_press_ms,
              notifications:
                [{"Esc again to clear input", now + @double_press_ms} | s.notifications]
                |> Enum.take(3)
          }
      end
    end)

    PromptStore.save_draft(buffer(state))
  end

  @doc false
  def edit_input(buffer, cursor, event) when is_binary(buffer) and is_integer(cursor) do
    Ourocode.Terminal.InputEditor.edit_input(buffer, cursor, event)
  end

  @history_limit 50

  defp remember_history(_state, ""), do: :ok

  defp remember_history(state, line) when is_binary(line) do
    Agent.update(state, fn s ->
      history =
        case List.first(s.history) do
          ^line -> s.history
          _other -> [line | s.history] |> Enum.take(@history_limit)
        end

      %{
        s
        | history: history,
          history_index: 0,
          history_draft: nil,
          ooo_cache: nil,
          ooo_cache_loaded_ms: nil
      }
    end)

    PromptStore.append_history(line)
  end

  defp move_history(state, direction) when direction in [-1, 1] do
    Agent.update(state, fn s ->
      count = length(s.history)

      cond do
        count == 0 ->
          s

        direction == -1 ->
          index = min(s.history_index + 1, count)
          draft = if s.history_index == 0, do: s.buffer, else: s.history_draft
          buffer = Enum.at(s.history, index - 1, "")

          %{
            s
            | history_index: index,
              history_draft: draft,
              buffer: buffer,
              cursor: String.length(buffer)
          }

        direction == 1 and s.history_index > 1 ->
          index = s.history_index - 1
          buffer = Enum.at(s.history, index - 1, "")
          %{s | history_index: index, buffer: buffer, cursor: String.length(buffer)}

        direction == 1 and s.history_index == 1 ->
          buffer = s.history_draft || ""

          %{
            s
            | history_index: 0,
              history_draft: nil,
              buffer: buffer,
              cursor: String.length(buffer)
          }

        true ->
          s
      end
    end)
  end

  defp reset_history_cursor(state) do
    Agent.update(state, fn s -> %{s | history_index: 0, history_draft: nil} end)
  end

  defp take_buffer(state) do
    PromptStore.clear_draft()
    Agent.get_and_update(state, fn s -> {s.buffer, %{s | buffer: "", cursor: 0}} end)
  end

  defp take_leftover(state) do
    Agent.get_and_update(state, fn s -> {s.leftover, %{s | leftover: ""}} end)
  end

  defp put_leftover(state, leftover) do
    Agent.update(state, fn s -> %{s | leftover: leftover} end)
  end

  defp prev_screen(state), do: Agent.get(state, & &1.prev_screen)

  defp put_prev_screen(state, screen) do
    Agent.update(state, fn s -> %{s | prev_screen: screen} end)
  end
end
