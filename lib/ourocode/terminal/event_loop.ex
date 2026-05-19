defmodule Ourocode.Terminal.EventLoop do
  @moduledoc """
  Persistent terminal input loop for the interactive baseline.

  The loop deliberately stays small: it owns terminal input continuity, accepts
  natural-language task submissions, and exits only on explicit user exit
  commands or stdin EOF for non-interactive smoke runs.
  """

  alias Ourocode.{Journal, Runtime, TaskRequest}
  alias Ourocode.Command.Registry, as: CommandRegistry
  alias Ourocode.Journal.ReplayLoader
  alias Ourocode.Runtime.Dispatcher
  alias Ourocode.Runtime.FocusState
  alias Ourocode.Terminal.FooterStateArea
  alias Ourocode.Terminal.PluginStatusArea
  alias Ourocode.Terminal.ParentWorkflowFeedback
  alias Ourocode.Terminal.CommandPaletteArea
  alias Ourocode.Runtime.CapabilityGraph

  @default_exit_commands MapSet.new(["/exit", "/quit", "exit", "quit", ":q"])
  @default_prompt "ourocode> "

  @type result :: %{
          required(:status) => :exit_signal_received | :input_eof,
          required(:iterations) => non_neg_integer(),
          required(:submitted_tasks) => [TaskRequest.t()],
          required(:input_events) => [map()],
          required(:accepted_input_buffer) => [map()],
          required(:runtime_events) => [map()],
          required(:plugin_status_updates) => [map()],
          required(:command_events) => [map()],
          required(:command_palette_events) => [map()],
          required(:command_errors) => [map()],
          required(:focus_events) => [map()],
          required(:focus_state) => map(),
          required(:pane_model) => map(),
          required(:recoverable_errors) => [map()],
          required(:prompt_state) => :awaiting_prompt | :dispatching_input,
          required(:prompt_state_events) => [map()],
          required(:exit_signal) => String.t() | nil,
          required(:resources_released?) => boolean()
        }

  @doc """
  Runs the terminal prompt loop until an explicit exit command or EOF.
  """
  @spec run(map(), keyword() | map()) :: {:ok, result()} | {:error, term()}
  def run(startup_result, options \\ []) when is_map(startup_result) do
    options = Map.new(options)
    prompt = Map.get(options, :prompt, @default_prompt)
    input = Map.get(options, :input, :stdio)
    output = Map.get(options, :output, :stdio)
    read_line = Map.get(options, :read_line, &IO.gets(input, &1))
    on_task = Map.get(options, :on_task, &default_task_handler/2)

    on_prompt_input =
      Map.get(options, :on_prompt_input, prompt_processor_from_task_handler(on_task))

    on_input_event = Map.get(options, :on_input_event, &default_input_event_handler/2)
    on_command = Map.get(options, :on_command, :default_command_handler)
    on_command_palette = Map.get(options, :on_command_palette, &default_command_palette_handler/2)

    on_command_palette_selection =
      Map.get(
        options,
        :on_command_palette_selection,
        &default_command_palette_selection_handler/2
      )

    on_focus_event = Map.get(options, :on_focus_event, &default_focus_event_handler/2)

    on_command_error =
      Map.get(options, :on_command_error, &default_command_error_handler/3)

    poll_runtime_event = Map.get(options, :poll_runtime_event, &default_runtime_event_poller/1)
    on_runtime_event = Map.get(options, :on_runtime_event, &default_runtime_event_handler/2)

    on_prompt_state_change =
      Map.get(options, :on_prompt_state_change, &default_prompt_state_change_handler/2)

    on_release_resources =
      Map.get(options, :on_release_resources, &default_release_resources/2)

    state = %{
      startup_result: startup_result,
      output: output,
      read_line: read_line,
      on_prompt_input: on_prompt_input,
      on_input_event: on_input_event,
      on_command: on_command,
      on_command_palette: on_command_palette,
      on_command_palette_selection: on_command_palette_selection,
      command_dispatch_options: Map.get(options, :command_dispatch_options, %{}),
      on_command_error: on_command_error,
      on_focus_event: on_focus_event,
      poll_runtime_event: poll_runtime_event,
      on_runtime_event: on_runtime_event,
      on_prompt_state_change: on_prompt_state_change,
      on_release_resources: on_release_resources,
      journal_path: Map.get(options, :journal_path),
      exit_signals: exit_signals(options),
      prompt: prompt,
      prompt_state: :awaiting_prompt,
      prompt_state_events: [],
      iterations: 0,
      submitted_tasks: [],
      input_events: [],
      accepted_input_buffer: [],
      runtime_events: [],
      plugin_status_updates: [],
      command_events: [],
      command_palette_events: [],
      active_command_palette: nil,
      command_errors: [],
      focus_events: [],
      focus_state: Map.get(options, :focus_state, FocusState.new()),
      pane_model: Map.get(options, :pane_model, default_pane_model()),
      keyboard_focus_bindings: keyboard_focus_bindings(options),
      recoverable_errors: []
    }

    loop(state)
  end

  @doc """
  Converts one natural-language terminal line into the normalized input event
  emitted by the prompt loop.
  """
  @spec normalize_input_line(String.t(), keyword() | map()) ::
          {:ok, {TaskRequest.t(), map()}} | {:error, String.t()}
  def normalize_input_line(line, options \\ [])

  def normalize_input_line(line, options) when is_binary(line) do
    options = Map.new(options)

    task_options =
      options
      |> Map.take([:id, :submitted_at_ms])
      |> Map.put(:source, Map.get(options, :task_source, :dashboard))

    with {:ok, task_request} <- TaskRequest.parse(line, task_options) do
      {:ok, {task_request, input_event(task_request, Map.put_new(options, :raw_input, line))}}
    end
  end

  def normalize_input_line(_line, _options), do: {:error, "input line must be a string"}

  @doc """
  Dispatches a normalized natural-language prompt event into the prompt
  processing path.

  This keeps the app input boundary event-first: terminal input is normalized
  and journaled before any prompt-processing callback receives it.
  """
  @spec dispatch_prompt_input_event(map(), map(), keyword() | map()) ::
          {:ok, TaskRequest.t()} | {:error, term()}
  def dispatch_prompt_input_event(input_event, startup_result, options \\ [])

  def dispatch_prompt_input_event(
        %{input_kind: :natural_language} = input_event,
        startup_result,
        options
      ) do
    options = Map.new(options)

    with :ok <- validate_prompt_input_event(input_event),
         {:ok, task_request} <- task_request_from_input_event(input_event) do
      prompt_processor =
        Map.get(options, :on_prompt_input, &default_prompt_input_handler/3)

      prompt_processor.(task_request, input_event, startup_result)
      {:ok, task_request}
    end
  end

  def dispatch_prompt_input_event(%{input_kind: input_kind}, _startup_result, _options) do
    {:error, {:unsupported_input_kind, input_kind}}
  end

  def dispatch_prompt_input_event(_input_event, _startup_result, _options) do
    {:error, :invalid_prompt_input_event}
  end

  @doc """
  Returns true only when a terminal line exactly matches an explicit exit
  command or an exit signal configured for this prompt loop.
  """
  @spec shutdown_signal?(term(), keyword() | map()) :: boolean()
  def shutdown_signal?(line, options \\ [])

  def shutdown_signal?(line, options) when is_binary(line) do
    line
    |> normalize_shutdown_signal()
    |> then(&MapSet.member?(exit_signals(Map.new(options)), &1))
  end

  def shutdown_signal?(_line, _options), do: false

  defp loop(state) do
    case drain_runtime_events(state) do
      {:ok, state} ->
        case state.read_line.(state.prompt) do
          :eof ->
            finish(:input_eof, nil, state)

          nil ->
            finish(:input_eof, nil, state)

          line when is_binary(line) ->
            handle_line(trim_terminal_line_ending(line), state)

          key_input when is_map(key_input) ->
            handle_keyboard_input(key_input, state)

          {:key, key} ->
            handle_keyboard_input(%{key: key}, state)

          other ->
            {:error, {:invalid_terminal_input, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_line("", state) do
    loop(%{state | iterations: state.iterations + 1})
  end

  defp handle_line(line, state) do
    if shutdown_signal?(line, exit_signals: state.exit_signals) do
      IO.puts(state.output, "exiting ourocode")
      shutdown(:exit_signal_received, line, %{state | iterations: state.iterations + 1})
    else
      cond do
        command_palette_selection?(line, state) -> select_command_palette_entry(line, state)
        command_palette_trigger?(line) -> open_command_palette(line, state)
        slash_command?(line) -> submit_command(line, state)
        true -> submit_task(line, state)
      end
    end
  end

  defp handle_keyboard_input(key_input, state) do
    case resolve_keyboard_focus_target(key_input, state) do
      {:ok, target_pane_id} ->
        maybe_switch_focus_from_keyboard(key_input, target_pane_id, state)

      :ignore ->
        loop(%{state | iterations: state.iterations + 1})
    end
  end

  defp maybe_switch_focus_from_keyboard(key_input, target_pane_id, state) do
    if same_pane?(state.focus_state.focused_pane, target_pane_id, state.pane_model) do
      loop(%{state | iterations: state.iterations + 1})
    else
      case FocusState.focus_pane(state.focus_state, target_pane_id, state.pane_model,
             occurred_at_ms: System.system_time(:millisecond)
           ) do
        {:ok, focus_state, focus_event} ->
          maybe_record_keyboard_focus_event(state, focus_state, focus_event, key_input)

        {:error, reason, _unchanged_state} ->
          keyboard_error = keyboard_focus_error_event(key_input, reason)
          maybe_append_input_event(state.journal_path, keyboard_error)

          loop(%{
            state
            | iterations: state.iterations + 1,
              recoverable_errors: [keyboard_error | state.recoverable_errors]
          })
      end
    end
  end

  defp maybe_record_keyboard_focus_event(state, focus_state, nil, _key_input) do
    loop(%{state | iterations: state.iterations + 1, focus_state: focus_state})
  end

  defp maybe_record_keyboard_focus_event(state, focus_state, focus_event, key_input) do
    focus_event = keyboard_focus_event(focus_event, key_input)

    case maybe_append_input_event(state.journal_path, focus_event) do
      :ok ->
        state.on_focus_event.(focus_event, state.startup_result)

        loop(%{
          state
          | iterations: state.iterations + 1,
            focus_state: focus_state,
            focus_events: [focus_event | state.focus_events]
        })

      {:error, reason} ->
        {:error, {:focus_event_journal_append_failed, reason}}
    end
  end

  defp submit_command(line, state) do
    command_event = command_event(line)

    case persist_accepted_input_event(state.journal_path, command_event) do
      {:ok, command_event} ->
        with {:ok, state} <- maybe_switch_focus_from_command(command_event, state) do
          case dispatch_command_event(command_event, state) do
            :ok ->
              loop(%{
                state
                | iterations: state.iterations + 1,
                  command_events: [command_event | state.command_events]
              })

            {:error, reason} ->
              command_error = command_error_event(command_event, reason)
              maybe_append_input_event(state.journal_path, command_error)
              state.on_command_error.(command_error, command_event, state.startup_result)
              report_command_error(state.output, command_event, reason)

              loop(%{
                state
                | iterations: state.iterations + 1,
                  command_events: [command_event | state.command_events],
                  command_errors: [command_error | state.command_errors]
              })
          end
        else
          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:command_event_journal_append_failed, reason}}
    end
  end

  defp open_command_palette(line, state) do
    palette_event = command_palette_open_event(line, state)

    case persist_palette_event(state.journal_path, palette_event) do
      {:ok, palette_event} ->
        render_command_palette(state.output, palette_event)
        state.on_command_palette.(palette_event, state.startup_result)
        {:ok, registry} = command_palette_registry(state)

        loop(%{
          state
          | iterations: state.iterations + 1,
            active_command_palette: %{registry: registry, opened_event: palette_event},
            command_palette_events: [palette_event | state.command_palette_events]
        })

      {:error, reason} ->
        {:error, {:command_palette_event_journal_append_failed, reason}}
    end
  end

  defp select_command_palette_entry(line, state) do
    %{registry: registry, opened_event: opened_event} = state.active_command_palette

    case CommandPaletteArea.select(registry, line) do
      {:ok, selected_entry} ->
        selection_event =
          command_palette_selection_event(line, selected_entry, opened_event, registry)

        case persist_palette_event(state.journal_path, selection_event) do
          {:ok, selection_event} ->
            IO.puts(state.output, "selected #{selected_entry.slash}: #{selected_entry.summary}")
            state.on_command_palette_selection.(selection_event, state.startup_result)

            loop(%{
              state
              | iterations: state.iterations + 1,
                active_command_palette: nil,
                command_palette_events: [selection_event | state.command_palette_events]
            })

          {:error, reason} ->
            {:error, {:command_palette_selection_event_journal_append_failed, reason}}
        end

      {:error, reason} ->
        selection_error =
          recoverable_error_event(:command_palette_selection_failed, reason, :terminal_prompt)

        case record_recoverable_error(selection_error, state) do
          {:ok, state} ->
            IO.puts(state.output, "palette selection failed: #{format_command_error(reason)}")
            loop(%{state | iterations: state.iterations + 1})

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp maybe_switch_focus_from_command(command_event, state) do
    case command_focus_target(command_event) do
      {:ok, target_pane_id} ->
        if same_pane?(state.focus_state.focused_pane, target_pane_id, state.pane_model) do
          {:ok, state}
        else
          switch_focus_from_command(command_event, target_pane_id, state)
        end

      :ignore ->
        {:ok, state}
    end
  end

  defp switch_focus_from_command(command_event, target_pane_id, state) do
    case FocusState.focus_pane(state.focus_state, target_pane_id, state.pane_model,
           occurred_at_ms: System.system_time(:millisecond)
         ) do
      {:ok, focus_state, focus_event} ->
        maybe_record_command_focus_event(state, focus_state, focus_event, command_event)

      {:error, _reason, _unchanged_state} ->
        {:ok, state}
    end
  end

  defp maybe_record_command_focus_event(state, focus_state, nil, _command_event) do
    {:ok, %{state | focus_state: focus_state}}
  end

  defp maybe_record_command_focus_event(state, focus_state, focus_event, command_event) do
    focus_event = command_focus_event(focus_event, command_event)

    case maybe_append_input_event(state.journal_path, focus_event) do
      :ok ->
        state.on_focus_event.(focus_event, state.startup_result)

        {:ok,
         %{
           state
           | focus_state: focus_state,
             focus_events: [focus_event | state.focus_events]
         }}

      {:error, reason} ->
        {:error, {:focus_event_journal_append_failed, reason}}
    end
  end

  defp drain_runtime_events(state) do
    case poll_runtime_event(state) do
      :none ->
        {:ok, state}

      {:ok, event} ->
        case submit_runtime_event(event, state) do
          {:ok, state} -> drain_runtime_events(state)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        recoverable_error =
          recoverable_error_event(
            :runtime_event_poll_failed,
            reason,
            :terminal_runtime_event_poll
          )

        case record_recoverable_error(recoverable_error, state) do
          {:ok, state} -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp poll_runtime_event(%{poll_runtime_event: poll_runtime_event} = state) do
    poll_result =
      cond do
        is_function(poll_runtime_event, 1) -> poll_runtime_event.(state)
        is_function(poll_runtime_event, 0) -> poll_runtime_event.()
        true -> :none
      end

    normalize_runtime_event_poll(poll_result)
  rescue
    exception ->
      {:error,
       {:runtime_event_poller_exception, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:runtime_event_poller_caught, kind, reason}}
  end

  defp normalize_runtime_event_poll(nil), do: :none
  defp normalize_runtime_event_poll(:none), do: :none
  defp normalize_runtime_event_poll(:empty), do: :none
  defp normalize_runtime_event_poll({:ok, nil}), do: :none
  defp normalize_runtime_event_poll({:ok, event}) when is_map(event), do: {:ok, event}
  defp normalize_runtime_event_poll(event) when is_map(event), do: {:ok, event}
  defp normalize_runtime_event_poll({:error, reason}), do: {:error, reason}
  defp normalize_runtime_event_poll(other), do: {:error, {:invalid_runtime_event_poll, other}}

  defp submit_runtime_event(event, state) do
    runtime_event = normalize_runtime_event(event)

    with :ok <- maybe_append_input_event(state.journal_path, runtime_event),
         {:ok, state} <- maybe_apply_plugin_config_reload(runtime_event, state),
         {:ok, state} <- dispatch_runtime_event(runtime_event, state) do
      state =
        %{state | runtime_events: [runtime_event | state.runtime_events]}
        |> maybe_record_recoverable_runtime_event(runtime_event)

      {:ok, state}
    else
      {:error, {:recoverable_runtime_event_handler_failed, reason}} ->
        recoverable_error =
          recoverable_error_event(
            :runtime_event_handler_failed,
            reason,
            Map.get(runtime_event, :type)
          )

        with {:ok, state} <- record_recoverable_error(recoverable_error, state) do
          {:ok, %{state | runtime_events: [runtime_event | state.runtime_events]}}
        end

      {:error, reason} ->
        {:error, {:runtime_event_append_failed, reason}}
    end
  end

  defp dispatch_runtime_event(runtime_event, state) do
    case state.on_runtime_event.(runtime_event, state.startup_result) do
      :ok -> {:ok, state}
      {:ok, _result} -> {:ok, state}
      {:error, reason} -> {:error, {:recoverable_runtime_event_handler_failed, reason}}
      other -> {:error, {:recoverable_runtime_event_handler_failed, {:invalid_result, other}}}
    end
  rescue
    exception ->
      {:error,
       {:recoverable_runtime_event_handler_failed,
        {:exception, exception.__struct__, Exception.message(exception)}}}
  catch
    kind, reason ->
      {:error, {:recoverable_runtime_event_handler_failed, {:caught, kind, reason}}}
  end

  defp normalize_runtime_event(event) do
    type =
      event
      |> event_value(:type, event_value(event, :event_type, :runtime_event))
      |> normalize_runtime_event_type()

    event
    |> Map.put(:type, type)
    |> Map.put_new(:source, :runtime)
    |> Map.put_new(:occurred_at_ms, System.system_time(:millisecond))
    |> Map.put_new(:event_type, type)
  end

  defp normalize_runtime_event_type(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_runtime_event_type(value), do: value

  defp maybe_record_recoverable_runtime_event(state, runtime_event) do
    if recoverable_runtime_event?(runtime_event) do
      recoverable_error =
        recoverable_error_event(
          Map.get(runtime_event, :type, :recoverable_runtime_event),
          Map.get(runtime_event, :reason) || Map.get(runtime_event, :error) || runtime_event,
          Map.get(runtime_event, :source, :runtime)
        )

      %{state | recoverable_errors: [recoverable_error | state.recoverable_errors]}
    else
      state
    end
  end

  defp recoverable_runtime_event?(%{recoverable?: true}), do: true
  defp recoverable_runtime_event?(%{severity: :recoverable}), do: true

  defp recoverable_runtime_event?(%{type: type})
       when type in [:recoverable_error, :recoverable_stream_gap], do: true

  defp recoverable_runtime_event?(_event), do: false

  defp record_recoverable_error(recoverable_error, state) do
    case maybe_append_input_event(state.journal_path, recoverable_error) do
      :ok -> {:ok, %{state | recoverable_errors: [recoverable_error | state.recoverable_errors]}}
      {:error, reason} -> {:error, {:recoverable_error_journal_append_failed, reason}}
    end
  end

  defp recoverable_error_event(type, reason, source) do
    %{
      type: :terminal_recoverable_error,
      event_type: :terminal_recoverable_error,
      source: source,
      recoverable?: true,
      error_type: type,
      reason: reason,
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        error_type: type,
        reason: reason
      }
    }
  end

  defp dispatch_command_event(command_event, state) do
    try do
      case invoke_command_handler(command_event, state) do
        :ok -> :ok
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_command_handler_result, other}}
      end
    rescue
      exception ->
        {:error, {:command_handler_exception, exception.__struct__, Exception.message(exception)}}
    catch
      kind, reason ->
        {:error, {:command_handler_caught, kind, reason}}
    end
  end

  defp invoke_command_handler(command_event, %{on_command: :default_command_handler} = state) do
    default_command_handler(command_event, command_event.args, state.startup_result, state)
  end

  defp invoke_command_handler(command_event, %{on_command: on_command} = state)
       when is_function(on_command, 4) do
    on_command.(command_event, command_event.args, state.startup_result, state)
  end

  defp invoke_command_handler(command_event, %{on_command: on_command} = state)
       when is_function(on_command, 3) do
    on_command.(command_event, command_event.args, state.startup_result)
  end

  defp invoke_command_handler(_command_event, %{on_command: on_command}) do
    {:error, {:invalid_command_handler, on_command}}
  end

  defp report_command_error(output, command_event, reason) do
    IO.puts(
      output,
      "command #{command_event.command} failed: #{format_command_error(reason)}"
    )
  end

  defp format_command_error(reason) when is_binary(reason), do: reason

  defp format_command_error({:unknown_command, command, []}) do
    "unknown command #{command}"
  end

  defp format_command_error({:unknown_command, command, suggestions}) when is_list(suggestions) do
    "unknown command #{command}. did you mean #{Enum.join(suggestions, ", ")}?"
  end

  defp format_command_error(reason) do
    inspect(reason, limit: 20, printable_limit: 200)
  end

  defp command_event(line) do
    {command, args} = parse_command(line)

    %{
      type: :slash_command_submitted,
      event_type: :slash_command_submitted,
      source: :terminal_prompt,
      input_kind: :slash_command,
      command: command,
      args: args,
      raw_input: line,
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        command: command,
        args: args,
        raw_input: line
      }
    }
  end

  defp command_error_event(command_event, reason) do
    %{
      type: :slash_command_failed,
      event_type: :slash_command_failed,
      source: :terminal_prompt,
      input_kind: :slash_command,
      command: command_event.command,
      args: command_event.args,
      raw_input: command_event.raw_input,
      reason: reason,
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        command: command_event.command,
        args: command_event.args,
        raw_input: command_event.raw_input,
        reason: reason
      }
    }
  end

  defp command_palette_open_event(line, state) do
    {:ok, registry} = command_palette_registry(state)
    entries = CommandPaletteArea.event_entries(registry)

    registry_summary = %{
      status: Map.get(registry, :status),
      loaded_count: Map.get(registry, :loaded_count, 0),
      sources: Map.get(registry, :sources, []),
      entries: entries
    }

    %{
      type: :command_palette_opened,
      event_type: :command_palette_opened,
      source: :terminal_prompt,
      input_kind: :slash_palette_trigger,
      action: :command_palette_open,
      raw_input: line,
      prompt_mutated?: false,
      submitted?: false,
      occurred_at_ms: System.system_time(:millisecond),
      registry: registry_summary,
      payload: %{
        action: :command_palette_open,
        raw_input: line,
        prompt_mutated?: false,
        submitted?: false,
        registry: registry_summary
      }
    }
  end

  defp command_palette_selection_event(line, selected_entry, opened_event, registry) do
    selection_index =
      registry
      |> CommandRegistry.entries()
      |> Enum.find_index(&(&1.slash == selected_entry.slash))
      |> case do
        nil -> nil
        index -> index + 1
      end

    selected_registry_item = selected_entry

    %{
      type: :command_palette_selected,
      event_type: :command_palette_selected,
      source: :terminal_prompt,
      input_kind: :slash_palette_selection,
      action: :command_palette_select,
      raw_input: line,
      prompt_mutated?: false,
      submitted?: false,
      selection_index: selection_index,
      selected_slash: selected_entry.slash,
      selected_registry_item: selected_registry_item,
      opened_event_seq: Map.get(opened_event, :event_seq),
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        action: :command_palette_select,
        raw_input: line,
        prompt_mutated?: false,
        submitted?: false,
        selection_index: selection_index,
        selected_slash: selected_entry.slash,
        selected_registry_item: selected_registry_item,
        opened_event_seq: Map.get(opened_event, :event_seq)
      }
    }
  end

  defp render_command_palette(output, %{registry: registry}) do
    registry
    |> command_palette_render_model()
    |> CommandPaletteArea.render_text()
    |> then(&IO.puts(output, &1))
  end

  defp command_palette_render_model(%{
         status: status,
         loaded_count: loaded_count,
         sources: sources,
         entries: entries
       }) do
    %{
      id: :command_palette,
      region: :command_palette,
      title: "Command Palette",
      status: status,
      loaded_count: loaded_count,
      sources: sources,
      entries: entries
    }
  end

  defp parse_command(line) do
    [command | args] =
      line
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    {command, args}
  end

  defp slash_command?(line) do
    line
    |> String.trim_leading()
    |> String.starts_with?("/")
  end

  defp command_palette_trigger?(line) do
    String.trim(line) == "/"
  end

  defp command_palette_selection?(_line, %{active_command_palette: nil}), do: false

  defp command_palette_selection?(line, %{active_command_palette: active_palette})
       when is_map(active_palette) and is_binary(line) do
    case Integer.parse(String.trim(line)) do
      {index, ""} when index > 0 -> true
      _other -> false
    end
  end

  defp trim_terminal_line_ending(line) when is_binary(line) do
    line
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end

  defp submit_task(line, state) do
    case normalize_input_line(line, focus_state: state.focus_state, raw_input: line) do
      {:ok, {_task_request, input_event}} ->
        case persist_accepted_input_event(state.journal_path, input_event) do
          {:ok, input_event} ->
            accepted_state =
              state
              |> append_steering_message_to_target_child_pane(input_event)
              |> buffer_accepted_input_event(input_event)

            accepted_state.on_input_event.(input_event, accepted_state.startup_result)

            dispatching_state =
              transition_prompt_state(accepted_state, :dispatching_input, input_event)

            render_parent_workflow_feedback(dispatching_state, input_event)

            case dispatch_prompt_input_event(input_event, dispatching_state.startup_result,
                   on_prompt_input: dispatching_state.on_prompt_input
                 ) do
              {:ok, dispatched_task_request} ->
                awaiting_state =
                  transition_prompt_state(dispatching_state, :awaiting_prompt, input_event)

                IO.puts(
                  awaiting_state.output,
                  "queued task #{dispatched_task_request.id}: #{dispatched_task_request.task_input}"
                )

                loop(%{
                  awaiting_state
                  | iterations: state.iterations + 1,
                    submitted_tasks: [dispatched_task_request | state.submitted_tasks],
                    input_events: [input_event | state.input_events]
                })

              {:error, reason} ->
                {:error, {:prompt_input_dispatch_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:input_event_journal_append_failed, reason}}
        end

      {:error, reason} ->
        IO.puts(state.output, "ignored input: #{reason}")
        loop(%{state | iterations: state.iterations + 1})
    end
  end

  defp shutdown(status, exit_signal, state) do
    with {:ok, state} <- drain_runtime_events(state),
         :ok <- release_active_resources(state) do
      finish(status, exit_signal, state, true)
    end
  end

  defp finish(status, exit_signal, state, resources_released? \\ false) do
    {:ok,
     %{
       status: status,
       iterations: state.iterations,
       submitted_tasks: Enum.reverse(state.submitted_tasks),
       input_events: Enum.reverse(state.input_events),
       accepted_input_buffer: Enum.reverse(state.accepted_input_buffer),
       runtime_events: Enum.reverse(state.runtime_events),
       plugin_status_updates: Enum.reverse(state.plugin_status_updates),
       command_events: Enum.reverse(state.command_events),
       command_palette_events: Enum.reverse(state.command_palette_events),
       command_errors: Enum.reverse(state.command_errors),
       focus_events: Enum.reverse(state.focus_events),
       focus_state: state.focus_state,
       pane_model: state.pane_model,
       recoverable_errors: Enum.reverse(state.recoverable_errors),
       prompt_state: state.prompt_state,
       prompt_state_events: Enum.reverse(state.prompt_state_events),
       exit_signal: exit_signal,
       resources_released?: resources_released?
     }}
  end

  defp release_active_resources(state) do
    case state.on_release_resources.(state.startup_result, state) do
      :ok -> :ok
      {:ok, _released} -> :ok
      {:error, reason} -> {:error, {:resource_release_failed, reason}}
      other -> {:error, {:resource_release_failed, {:invalid_result, other}}}
    end
  rescue
    exception ->
      {:error,
       {:resource_release_failed,
        {:exception, exception.__struct__, Exception.message(exception)}}}
  catch
    kind, reason ->
      {:error, {:resource_release_failed, {:caught, kind, reason}}}
  end

  defp transition_prompt_state(state, prompt_state, input_event) do
    state_event = prompt_state_event(prompt_state, input_event)
    state.on_prompt_state_change.(state_event, state.startup_result)

    %{
      state
      | prompt_state: prompt_state,
        prompt_state_events: [state_event | state.prompt_state_events]
    }
  end

  defp render_parent_workflow_feedback(state, input_event) do
    state_event = hd(state.prompt_state_events)

    IO.puts(
      state.output,
      ParentWorkflowFeedback.render_text(input_event, state_event)
    )
  end

  defp prompt_state_event(:dispatching_input, input_event) do
    %{
      type: :prompt_loop_state_changed,
      event_type: :prompt_loop_state_changed,
      source: :terminal_prompt,
      prompt_state: :dispatching_input,
      reason: :input_dispatch_started,
      task_request_id: input_event.task_request_id,
      occurred_at_ms: System.system_time(:millisecond)
    }
  end

  defp prompt_state_event(:awaiting_prompt, input_event) do
    %{
      type: :prompt_loop_state_changed,
      event_type: :prompt_loop_state_changed,
      source: :terminal_prompt,
      prompt_state: :awaiting_prompt,
      reason: :input_dispatch_completed,
      task_request_id: input_event.task_request_id,
      occurred_at_ms: System.system_time(:millisecond)
    }
  end

  defp input_event(%TaskRequest{} = task_request, options) do
    focus_state = Map.get(options, :focus_state, FocusState.new())
    focused_pane = Map.get(focus_state, :focused_pane, :task_prompt)
    steering_target = Map.get(focus_state, :steering_target, :parent)
    steering_target_pane_id = Map.get(focus_state, :steering_target_pane_id, focused_pane)
    steering_target_session_id = Map.get(focus_state, :steering_target_session_id)
    steering_target_kind = Map.get(focus_state, :steering_target_kind)
    steering_text = Map.get(options, :raw_input, task_request.task_input)

    %{
      type: :prompt_input_submitted,
      event_type: :prompt_input_submitted,
      source: :terminal_prompt,
      input_kind: :natural_language,
      focused_pane: focused_pane,
      steering_target: steering_target,
      steering_target_pane_id: steering_target_pane_id,
      steering_target_session_id: steering_target_session_id,
      steering_target_kind: steering_target_kind,
      task_request_id: task_request.id,
      task_input: task_request.task_input,
      raw_input: steering_text,
      steering_text: steering_text,
      steering_message:
        pane_directed_steering_message(
          steering_target_pane_id,
          steering_text,
          steering_target_session_id,
          steering_target_kind
        ),
      submitted_at_ms: task_request.submitted_at_ms,
      occurred_at_ms: Map.get(options, :occurred_at_ms, task_request.submitted_at_ms),
      routing_decision: task_request.routing_decision,
      payload: %{
        task_request_id: task_request.id,
        task_source: task_request.source,
        task_input: task_request.task_input,
        raw_input: steering_text,
        steering_text: steering_text,
        focused_pane: focused_pane,
        steering_target: steering_target,
        steering_target_pane_id: steering_target_pane_id,
        steering_target_session_id: steering_target_session_id,
        steering_target_kind: steering_target_kind,
        steering_message:
          pane_directed_steering_message(
            steering_target_pane_id,
            steering_text,
            steering_target_session_id,
            steering_target_kind
          )
      }
    }
  end

  defp pane_directed_steering_message(
         target_pane_id,
         content,
         target_session_id,
         target_kind
       ) do
    %{
      type: :pane_directed_steering_message,
      target_pane_id: target_pane_id,
      content: content,
      target_session_id: target_session_id,
      target_kind: target_kind
    }
  end

  defp validate_prompt_input_event(%{
         type: :prompt_input_submitted,
         event_type: :prompt_input_submitted,
         source: :terminal_prompt,
         task_request_id: task_request_id,
         task_input: task_input,
         steering_text: steering_text,
         steering_message: %{
           type: :pane_directed_steering_message,
           target_pane_id: _target_pane_id,
           content: steering_text
         },
         submitted_at_ms: submitted_at_ms,
         payload: %{task_source: task_source}
       })
       when is_binary(task_request_id) and is_binary(task_input) and is_binary(steering_text) and
              is_integer(submitted_at_ms) and
              task_source in [:cli, :dashboard] do
    :ok
  end

  defp validate_prompt_input_event(_input_event), do: {:error, :invalid_prompt_input_event}

  defp task_request_from_input_event(input_event) do
    TaskRequest.parse(input_event.task_input,
      id: input_event.task_request_id,
      source: input_event.payload.task_source,
      submitted_at_ms: input_event.submitted_at_ms
    )
  end

  defp maybe_append_input_event(nil, _input_event), do: :ok

  defp maybe_append_input_event(journal_path, input_event) when is_binary(journal_path) do
    Journal.append(journal_path, input_event)
  end

  defp persist_palette_event(nil, palette_event), do: {:ok, palette_event}

  defp persist_palette_event(journal_path, palette_event) when is_binary(journal_path) do
    with {:ok, journaled_event} <- Journal.append_returning_event(journal_path, palette_event) do
      {:ok, Map.put(palette_event, :event_seq, journaled_event.event_seq)}
    end
  end

  defp persist_accepted_input_event(nil, input_event), do: {:ok, input_event}

  defp persist_accepted_input_event(journal_path, input_event) when is_binary(journal_path) do
    with {:ok, journaled_event} <- Journal.append_returning_event(journal_path, input_event) do
      {:ok, Map.put(input_event, :event_seq, journaled_event.event_seq)}
    end
  end

  defp maybe_apply_plugin_config_reload(%{type: :plugin_config_reload_requested} = event, state) do
    case runtime_from_startup(state.startup_result) do
      {:ok, runtime} ->
        reload_options =
          [
            occurred_at_ms: Map.get(event, :occurred_at_ms),
            project_dir: project_dir_from_startup(state.startup_result)
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        case Runtime.Application.handle_plugin_config_reload(runtime, event, reload_options) do
          {:ok, reload_result} ->
            {:ok, apply_plugin_status_update(state, reload_result)}

          {:error, reason} ->
            {:error, {:recoverable_runtime_event_handler_failed, reason}}
        end

      :error ->
        {:ok, state}
    end
  end

  defp maybe_apply_plugin_config_reload(%{type: :plugin_config_reloaded} = event, state) do
    case plugin_status_from_reloaded_event(event) do
      {:ok, plugin_status} ->
        {:ok,
         apply_plugin_status_update(state, %{
           status: event_value(event, :status, :loaded),
           plugins: plugin_status,
           event: event
         })}

      :error ->
        {:ok, state}
    end
  end

  defp maybe_apply_plugin_config_reload(_event, state), do: {:ok, state}

  defp plugin_status_from_reloaded_event(event) do
    configured_plugins = event_value(event, :configured_plugins, [])

    if is_list(configured_plugins) and configured_plugins != [] do
      {:ok,
       %{
         status: event_value(event, :status, :loaded),
         config_loaded?: event_value(event, :status) in [:loaded, "loaded"],
         configured_plugins: configured_plugins,
         enabled_plugins: event_value(event, :enabled_plugins, []),
         disabled_plugins: event_value(event, :disabled_plugins, []),
         plugins_by_id:
           event_value(event, :plugins_by_id, Map.new(configured_plugins, &{plugin_id(&1), &1})),
         load_transitions: event_value(event, :load_transitions, []),
         plugin_transitions:
           event_value(event, :plugin_transitions, event_value(event, :load_transitions, [])),
         last_reload:
           Map.take(event, [
             :status,
             :request_id,
             :change,
             :source,
             :occurred_at_ms,
             :reload_boundary,
             :ui_restart_required?
           ])
       }}
    else
      :error
    end
  end

  defp event_value(map, key, default \\ nil)

  defp event_value(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp event_value(_map, _key, default), do: default

  defp plugin_id(plugin) when is_map(plugin) do
    event_value(plugin, :id) || event_value(plugin, :plugin_id) || "plugin"
  end

  defp apply_plugin_status_update(state, reload_result) do
    plugin_status = Map.fetch!(reload_result, :plugins)
    reload_event = Map.fetch!(reload_result, :event)
    startup_result = put_plugin_status(state.startup_result, plugin_status)
    status_area = PluginStatusArea.render(%{runtime: %{plugin_status: plugin_status}})

    IO.puts(state.output, PluginStatusArea.render_text(status_area))

    %{
      state
      | startup_result: startup_result,
        plugin_status_updates: [
          %{
            type: :terminal_plugin_status_updated,
            event_type: :terminal_plugin_status_updated,
            source: :terminal_runtime_event_loop,
            status: Map.get(reload_result, :status),
            reload_event: reload_event,
            plugin_status: plugin_status,
            rendered_area: status_area,
            ui_restart_required?: false,
            occurred_at_ms: Map.get(reload_event, :occurred_at_ms)
          }
          | state.plugin_status_updates
        ]
    }
  end

  defp runtime_from_startup(%{runtime: runtime}) when is_map(runtime), do: {:ok, runtime}

  defp runtime_from_startup(%{context: %{runtime: runtime}}) when is_map(runtime),
    do: {:ok, runtime}

  defp runtime_from_startup(_startup_result), do: :error

  defp project_dir_from_startup(%{context: %{project_dir: project_dir}})
       when is_binary(project_dir),
       do: project_dir

  defp project_dir_from_startup(%{project_dir: project_dir}) when is_binary(project_dir),
    do: project_dir

  defp project_dir_from_startup(_startup_result), do: nil

  defp put_plugin_status(startup_result, plugin_status) do
    startup_result
    |> Map.put(:plugin_status, plugin_status)
    |> put_nested_plugin_status(:runtime, plugin_status)
    |> Map.update(:context, %{plugin_status: plugin_status}, fn context ->
      context
      |> Map.put(:plugin_status, plugin_status)
      |> put_nested_plugin_status(:runtime, plugin_status)
    end)
  end

  defp put_nested_plugin_status(map, key, plugin_status) do
    Map.update(map, key, %{plugin_status: plugin_status}, fn
      nested when is_map(nested) -> Map.put(nested, :plugin_status, plugin_status)
      _nested -> %{plugin_status: plugin_status}
    end)
  end

  defp buffer_accepted_input_event(state, input_event) do
    %{state | accepted_input_buffer: [input_event | state.accepted_input_buffer]}
  end

  defp append_steering_message_to_target_child_pane(
         %{pane_model: %{panes: panes} = pane_model} = state,
         %{steering_target: steering_target, steering_target_pane_id: target_pane_id} =
           input_event
       )
       when steering_target in [:child, "child"] and is_map(panes) do
    case fetch_concrete_child_pane(panes, target_pane_id) do
      {:ok, pane_key, pane} ->
        updated_pane = append_steering_stream_entry(pane, input_event)
        %{state | pane_model: %{pane_model | panes: Map.put(panes, pane_key, updated_pane)}}

      :ignore ->
        state
    end
  end

  defp append_steering_message_to_target_child_pane(state, _input_event), do: state

  defp fetch_concrete_child_pane(panes, target_pane_id) do
    target_key = pane_key(target_pane_id)

    Enum.find_value(panes, :ignore, fn {pane_key, pane} ->
      if concrete_child_pane?(pane, target_key) do
        {:ok, pane_key, pane}
      else
        false
      end
    end)
  end

  defp concrete_child_pane?(pane, target_key) when is_map(pane) do
    pane_id = pane |> Map.get(:id, Map.get(pane, "id")) |> pane_key()
    kind = Map.get(pane, :kind, Map.get(pane, "kind"))

    pane_id == target_key and kind in [:child_session, "child_session"]
  end

  defp concrete_child_pane?(_pane, _target_key), do: false

  defp append_steering_stream_entry(pane, input_event) when is_map(pane) do
    pane_state = Map.get(pane, :pane_state, Map.get(pane, "pane_state", %{}))
    pane_state = if is_map(pane_state), do: pane_state, else: %{}
    stream_entries = Map.get(pane_state, :stream_entries, [])
    stream_entries = if is_list(stream_entries), do: stream_entries, else: []

    updated_pane_state =
      pane_state
      |> Map.put(:stream_entries, stream_entries ++ [steering_stream_entry(input_event)])
      |> Map.put(:last_event_seq, Map.get(input_event, :event_seq))

    Map.put(pane, :pane_state, updated_pane_state)
  end

  defp steering_stream_entry(input_event) do
    steering_message = Map.get(input_event, :steering_message, %{})

    %{
      type: :pane_directed_steering_message,
      event_seq: Map.get(input_event, :event_seq),
      task_request_id: Map.get(input_event, :task_request_id),
      content: Map.get(steering_message, :content, Map.get(input_event, :steering_text)),
      target_pane_id:
        Map.get(steering_message, :target_pane_id, Map.get(input_event, :steering_target_pane_id)),
      target_session_id:
        Map.get(
          steering_message,
          :target_session_id,
          Map.get(input_event, :steering_target_session_id)
        ),
      target_kind:
        Map.get(steering_message, :target_kind, Map.get(input_event, :steering_target_kind)),
      payload: steering_message,
      occurred_at_ms: Map.get(input_event, :occurred_at_ms)
    }
  end

  defp resolve_keyboard_focus_target(key_input, state) do
    cond do
      not keyboard_input?(key_input) ->
        :ignore

      Map.has_key?(key_input, :target_pane_id) ->
        {:ok, Map.fetch!(key_input, :target_pane_id)}

      Map.has_key?(key_input, :target_pane) ->
        {:ok, Map.fetch!(key_input, :target_pane)}

      Map.has_key?(key_input, :pane_id) ->
        {:ok, Map.fetch!(key_input, :pane_id)}

      true ->
        key = normalized_key(Map.get(key_input, :key))

        case Map.fetch(state.keyboard_focus_bindings, key) do
          {:ok, target_pane_id} -> {:ok, target_pane_id}
          :error -> :ignore
        end
    end
  end

  defp keyboard_input?(%{input_kind: :keyboard}), do: true
  defp keyboard_input?(%{type: :keyboard_input}), do: true
  defp keyboard_input?(%{key: _key}), do: true
  defp keyboard_input?(_key_input), do: false

  defp keyboard_focus_event(focus_event, key_input) do
    focus_event
    |> Map.put(:source, :terminal_keyboard)
    |> Map.put(:input_kind, :keyboard)
    |> Map.put(:key, Map.get(key_input, :key))
    |> Map.put(:raw_input, key_input)
    |> Map.put(:payload, %{
      focused_pane: focus_event.focused_pane,
      previous_focused_pane: focus_event.previous_focused_pane,
      steering_target: focus_event.steering_target,
      steering_target_pane_id: Map.get(focus_event, :steering_target_pane_id),
      steering_target_session_id: Map.get(focus_event, :steering_target_session_id),
      steering_target_kind: Map.get(focus_event, :steering_target_kind),
      key: Map.get(key_input, :key),
      raw_input: key_input
    })
  end

  defp keyboard_focus_error_event(key_input, reason) do
    %{
      type: :keyboard_focus_failed,
      event_type: :keyboard_focus_failed,
      source: :terminal_keyboard,
      input_kind: :keyboard,
      recoverable?: true,
      reason: reason,
      key: Map.get(key_input, :key),
      raw_input: key_input,
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        reason: reason,
        key: Map.get(key_input, :key),
        raw_input: key_input
      }
    }
  end

  defp command_focus_target(%{command: command, args: [target_pane_id | _args]})
       when command in ["/pane", "/focus", "/focus-pane"] do
    {:ok, target_pane_id}
  end

  defp command_focus_target(%{command: command, args: args})
       when command in ["/pane", "/focus", "/focus-pane"] and args in [[], nil] do
    :ignore
  end

  defp command_focus_target(_command_event), do: :ignore

  defp command_focus_event(focus_event, command_event) do
    focus_event
    |> Map.put(:source, :terminal_command)
    |> Map.put(:input_kind, :slash_command)
    |> Map.put(:command, command_event.command)
    |> Map.put(:args, command_event.args)
    |> Map.put(:raw_input, command_event.raw_input)
    |> Map.put(:payload, %{
      command: command_event.command,
      args: command_event.args,
      raw_input: command_event.raw_input,
      focused_pane: focus_event.focused_pane,
      previous_focused_pane: focus_event.previous_focused_pane,
      steering_target: focus_event.steering_target,
      steering_target_pane_id: Map.get(focus_event, :steering_target_pane_id),
      steering_target_session_id: Map.get(focus_event, :steering_target_session_id),
      steering_target_kind: Map.get(focus_event, :steering_target_kind)
    })
  end

  defp same_pane?(focused_pane, target_pane_id, pane_model) do
    if FocusState.valid_pane?(target_pane_id, pane_model) do
      pane_key(focused_pane) == pane_key(target_pane_id)
    else
      false
    end
  end

  defp pane_key(pane_id) when is_atom(pane_id), do: Atom.to_string(pane_id)
  defp pane_key(pane_id) when is_binary(pane_id), do: pane_id
  defp pane_key(pane_id), do: inspect(pane_id)

  defp keyboard_focus_bindings(options) do
    defaults = %{
      "tab" => :children,
      "shift_tab" => :parent,
      "ctrl_p" => :parent,
      "ctrl_c" => :children,
      "ctrl_q" => :queue,
      "ctrl_s" => :status,
      "ctrl_w" => :wonder_tool
    }

    configured =
      options
      |> Map.get(:keyboard_focus_bindings, %{})
      |> Enum.into(%{}, fn {key, target_pane_id} -> {normalized_key(key), target_pane_id} end)

    Map.merge(defaults, configured)
  end

  defp normalized_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalized_key()

  defp normalized_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

  defp normalized_key(key), do: inspect(key)

  defp default_pane_model do
    %{
      panes: %{
        task_prompt: %{id: :task_prompt, kind: :prompt_input},
        parent: %{id: :parent, kind: :parent_session},
        children: %{id: :children, kind: :child_sessions},
        queue: %{id: :queue, kind: :queued_notifications},
        status: %{id: :status, kind: :status_area},
        wonder_tool: %{id: :wonder_tool, kind: :wonder_tool}
      },
      open: [:task_prompt, :parent, :children, :queue, :status, :wonder_tool]
    }
  end

  defp exit_signals(options) do
    configured =
      options
      |> Map.get(:exit_signals, [])
      |> normalize_configured_exit_signals()

    MapSet.union(@default_exit_commands, configured)
  end

  defp normalize_configured_exit_signals(signals) when is_list(signals) do
    signals
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_shutdown_signal/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_configured_exit_signals(%MapSet{} = signals) do
    signals
    |> MapSet.to_list()
    |> normalize_configured_exit_signals()
  end

  defp normalize_configured_exit_signals(_signals), do: MapSet.new()

  defp normalize_shutdown_signal(line) do
    line
    |> String.trim()
    |> String.downcase()
  end

  defp prompt_processor_from_task_handler(on_task) when is_function(on_task, 2) do
    fn task_request, _input_event, startup_result ->
      on_task.(task_request, startup_result)
    end
  end

  defp default_task_handler(_task_request, _startup_result), do: :ok
  defp default_prompt_input_handler(_task_request, _input_event, _startup_result), do: :ok
  defp default_input_event_handler(_input_event, _startup_result), do: :ok
  defp default_command_palette_handler(_palette_event, _startup_result), do: :ok
  defp default_command_palette_selection_handler(_selection_event, _startup_result), do: :ok
  defp default_runtime_event_poller(_state), do: :none
  defp default_runtime_event_handler(_runtime_event, _startup_result), do: :ok
  defp default_focus_event_handler(_focus_event, _startup_result), do: :ok

  defp default_release_resources(%{runtime: runtime}, _state),
    do: Runtime.Application.stop(runtime)

  defp default_release_resources(_startup_result, _state), do: :ok

  defp default_command_handler(command_event, _args, _startup_result, state) do
    with {:ok, registry} <- command_palette_registry(state),
         {:ok, entry} <- CommandRegistry.fetch(registry, command_event.command) do
      dispatch_builtin_command_entry(command_event, entry, state)
    else
      :error -> {:error, unknown_command_reason(command_event.command, state)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unknown_command_reason(command, state) do
    suggestions =
      with {:ok, registry} <- command_palette_registry(state) do
        command_suggestions(registry, command)
      else
        _error -> []
      end

    {:unknown_command, command, suggestions}
  end

  defp command_suggestions(registry, command) do
    needle = normalize_command_token(command)

    registry
    |> CommandRegistry.entries()
    |> Enum.flat_map(fn entry ->
      [entry.slash | Map.get(entry, :aliases, [])]
      |> Enum.map(fn token ->
        {entry.slash, token, edit_distance(needle, normalize_command_token(token))}
      end)
    end)
    |> Enum.sort_by(fn {_slash, token, distance} -> {distance, String.length(token), token} end)
    |> Enum.reduce([], fn {slash, _token, distance}, acc ->
      if slash in acc or distance > max(3, div(String.length(needle), 2)),
        do: acc,
        else: acc ++ [slash]
    end)
    |> Enum.take(3)
  end

  defp normalize_command_token(token) do
    token
    |> to_string()
    |> String.trim()
    |> String.trim_leading("/")
    |> String.downcase()
  end

  defp edit_distance(a, b) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)
    previous = Enum.to_list(0..length(b_chars))

    a_chars
    |> Enum.with_index(1)
    |> Enum.reduce(previous, fn {a_char, i}, prev ->
      {_left, row} =
        b_chars
        |> Enum.with_index(1)
        |> Enum.reduce({i, [i]}, fn {b_char, j}, {left, row} ->
          insert = left + 1
          delete = Enum.at(prev, j) + 1
          replace = Enum.at(prev, j - 1) + if(a_char == b_char, do: 0, else: 1)
          value = min(insert, min(delete, replace))
          {value, [value | row]}
        end)

      Enum.reverse(row)
    end)
    |> List.last()
  end

  defp default_command_registry(%{commands: %{entries: entries, aliases: aliases} = registry})
       when is_map(entries) and is_map(aliases),
       do: {:ok, registry}

  defp default_command_registry(%{
         runtime: %{commands: %{entries: entries, aliases: aliases} = registry}
       })
       when is_map(entries) and is_map(aliases),
       do: {:ok, registry}

  defp default_command_registry(%{
         context: %{runtime: %{commands: %{entries: entries, aliases: aliases} = registry}}
       })
       when is_map(entries) and is_map(aliases),
       do: {:ok, registry}

  defp default_command_registry(_startup_result), do: CommandRegistry.load_builtin()

  defp command_palette_registry(state) do
    with {:ok, registry} <- default_command_registry(state.startup_result) do
      CommandRegistry.expose_contextual_actions(registry,
        focus_state: state.focus_state,
        pane_model: state.pane_model
      )
    end
  end

  defp dispatch_builtin_command_entry(command_event, %{run_spec: run_spec} = entry, state) do
    command_event =
      command_event
      |> Map.put(:run_spec, run_spec)
      |> Map.put(:command_entry, entry)

    case Map.get(run_spec, :action) do
      :interrupt_focused_child ->
        Dispatcher.dispatch_interrupt_action(command_event, command_dispatch_options(state))

      :cancel_focused_child ->
        Dispatcher.dispatch_cancel_action(command_event, command_dispatch_options(state))

      :resume_session ->
        resume_session_command(command_event, state)

      :replay_journal ->
        resume_session_command(command_event, state)

      :show_help ->
        render_registry_command(state.output, state, :all)

      :show_commands ->
        render_registry_command(state.output, state, :all)

      :show_skills ->
        render_registry_command(state.output, state, :skills)

      :show_capabilities ->
        render_capability_graph(state.output, state)

      :show_status ->
        IO.puts(state.output, FooterStateArea.render_text(state.startup_result))
        IO.puts(state.output, PluginStatusArea.render_text(state.startup_result))
        render_sessions_status(state.output, state)
        {:ok, %{status: :rendered}}

      :show_plugins ->
        IO.puts(state.output, PluginStatusArea.render_text(state.startup_result))
        {:ok, %{status: :rendered}}

      :show_mcp ->
        render_stub_status(state.output, "mcp", "stdio,SSE,streamable_http")

      :show_sessions ->
        render_sessions_status(state.output, state)

      :show_config ->
        render_stub_status(state.output, "config", "plugin/runtime config; use /reload to reload")

      :show_queue ->
        render_stub_status(
          state.output,
          "queue",
          "queued notifications are shown near the prompt"
        )

      :show_hooks ->
        render_stub_status(
          state.output,
          "hooks",
          "hook lifecycle activity is in the footer/status area"
        )

      :show_wonder_tool ->
        render_stub_status(
          state.output,
          "wonderTool",
          "active questions render in the interaction area"
        )

      _action ->
        {:ok, %{command_entry: entry}}
    end
  end

  defp render_capability_graph(output, state) do
    with {:ok, registry} <- command_palette_registry(state) do
      graph = CapabilityGraph.build(registry)
      IO.puts(output, CapabilityGraph.render_text(graph))
      {:ok, %{count: graph.summary.count, graph: graph}}
    end
  end

  defp render_registry_command(output, state, filter) do
    with {:ok, registry} <- command_palette_registry(state) do
      entries =
        case filter do
          :skills ->
            CommandRegistry.query(registry,
              sources: [:local, :bundled_skill, :plugin, :dynamic_skill]
            )

          :all ->
            CommandRegistry.entries(registry)
        end

      IO.puts(output, "commands:")

      Enum.each(entries, fn entry ->
        IO.puts(output, "  #{entry.slash} [#{entry.source}/#{entry.category}] #{entry.summary}")
      end)

      {:ok, %{count: length(entries)}}
    end
  end

  defp render_sessions_status(output, state) do
    panes = Map.get(state.pane_model, :panes, %{})
    IO.puts(output, "sessions:")

    panes
    |> Enum.filter(fn {_id, pane} -> Map.get(pane, :kind) == :child_session end)
    |> Enum.each(fn {id, pane} ->
      session_id = Map.get(pane, :child_id) || Map.get(pane, :session_id) || id
      IO.puts(output, "  #{id} session=#{session_id}")
    end)

    {:ok, %{count: map_size(panes)}}
  end

  defp render_stub_status(output, label, message) do
    IO.puts(output, "#{label}: #{message}")
    {:ok, %{status: :rendered}}
  end

  defp resume_session_command(command_event, state) do
    case command_event.args do
      [] ->
        sessions = list_resume_sessions(state)
        render_resume_sessions(state.output, sessions)
        {:ok, %{sessions: sessions}}

      [target | _rest] ->
        with {:ok, path} <- resolve_resume_session_path(state, target),
             {:ok, %{events: events, report: report}} <- ReplayLoader.load(path) do
          IO.puts(
            state.output,
            "resumed #{Path.basename(path, ".jsonl")}: #{length(events)} events replayed"
          )

          {:ok, %{path: path, events: events, report: report}}
        else
          {:error, reason} ->
            {:error, {:resume_session_failed, reason}}
        end
    end
  end

  defp list_resume_sessions(state) do
    state
    |> resume_journal_dir()
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      %{
        id: Path.basename(path, ".jsonl"),
        path: path,
        event_count: journal_event_count(path)
      }
    end)
  end

  defp render_resume_sessions(output, []) do
    IO.puts(output, "resume: no journaled sessions found")
  end

  defp render_resume_sessions(output, sessions) do
    IO.puts(output, "resume: journaled sessions")

    Enum.each(sessions, fn session ->
      IO.puts(output, "  #{session.id} events=#{session.event_count} path=#{session.path}")
    end)
  end

  defp resolve_resume_session_path(state, target) do
    sessions = list_resume_sessions(state)

    cond do
      session = Enum.find(sessions, &(&1.id == target)) ->
        {:ok, session.path}

      File.regular?(target) ->
        {:ok, target}

      true ->
        {:error, {:unknown_resume_session, target}}
    end
  end

  defp resume_journal_dir(%{journal_path: path}) when is_binary(path), do: Path.dirname(path)

  defp resume_journal_dir(%{startup_result: startup_result}) do
    startup_result
    |> get_in([:runtime, :journal, :path])
    |> case do
      path when is_binary(path) -> Path.dirname(path)
      _other -> Path.join([File.cwd!(), ".ourocode", "journals"])
    end
  end

  defp journal_event_count(path) do
    case Journal.read_ordered(path) do
      {:ok, events} -> length(events)
      {:error, _reason} -> 0
    end
  end

  defp command_dispatch_options(state) do
    (state.command_dispatch_options || %{})
    |> Map.new()
    |> Map.put(:focus_state, state.focus_state)
    |> Map.put(:pane_model, state.pane_model)
  end

  defp default_command_error_handler(_command_error, _command_event, _startup_result), do: :ok
  defp default_prompt_state_change_handler(_state_event, _startup_result), do: :ok
end
