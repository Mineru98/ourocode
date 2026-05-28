defmodule Ourocode.CLI.SmokeTest do
  @moduledoc """
  Non-interactive startup smoke path for the terminal-native baseline.

  Smoke mode validates the CLI/config entrypoint, starts the minimal Elixir
  agent runtime services required for terminal startup, journals the successful
  startup state, and exits without booting the full terminal UI or entering the
  persistent prompt loop.
  """

  @default_timeout_ms 5_000

  @doc """
  Runs the smoke path against an already resolved startup context.
  """
  @spec run(map(), keyword() | map()) :: {:ok, map()} | {:error, map()}
  def run(context, options \\ []) when is_map(context) do
    options = Map.new(options)

    case Ourocode.Terminal.NetworkListenerGuard.verify_core_interaction_config(
           context_config: Map.get(context, :config, %{})
         ) do
      {:ok, core_interaction_config_guard} ->
        run_runtime_smoke(context, options, core_interaction_config_guard)

      {:error, reason} ->
        unhealthy_result(context, reason)
    end
  end

  defp run_runtime_smoke(context, options, core_interaction_config_guard) do
    runtime_application = Map.get(options, :runtime_application, Ourocode.Runtime.Application)
    timeout_ms = smoke_timeout_ms(options)

    case run_bounded(:startup, timeout_ms, fn ->
           runtime_application.bootstrap(runtime_context(context, options))
         end) do
      {:ok, runtime} ->
        case record_startup_state(runtime, context, core_interaction_config_guard) do
          :ok ->
            startup_state = startup_state(runtime)

            case run_bounded(:shutdown, timeout_ms, fn ->
                   runtime_application.shutdown(runtime, timeout_ms: timeout_ms)
                 end) do
              shutdown_state when is_map(shutdown_state) ->
                result = %{
                  status: smoke_status(shutdown_state),
                  healthy?: shutdown_state.orderly?,
                  mode: :smoke_test,
                  terminal_native?: true,
                  interactive_ui_started?: false,
                  event_loop_started?: false,
                  timeout_ms: timeout_ms,
                  runtime: startup_state,
                  shutdown: shutdown_state,
                  checked_at_ms: monotonic_ms(),
                  context: context,
                  core_interaction_config_guard: core_interaction_config_guard,
                  checks:
                    checks(context, startup_state, shutdown_state, core_interaction_config_guard)
                }

                maybe_emit_summary(result, options)
                {:ok, result}

              {:error, %{reason: :smoke_test_timeout} = timeout_result} ->
                failure =
                  timeout_result
                  |> Map.put(:runtime, startup_state)
                  |> Map.put(:core_interaction_config_guard, core_interaction_config_guard)
                  |> Map.put(
                    :checks,
                    timeout_checks(context, startup_state, core_interaction_config_guard)
                  )

                maybe_emit_summary(failure, options)
                {:error, failure}

              {:error, shutdown_error} ->
                failure =
                  unhealthy_result(context, :shutdown_failed)
                  |> elem(1)
                  |> Map.put(:details, shutdown_error)
                  |> Map.put(:timeout_ms, timeout_ms)
                  |> Map.put(:runtime, startup_state)
                  |> Map.put(:core_interaction_config_guard, core_interaction_config_guard)
                  |> Map.put(
                    :checks,
                    timeout_checks(context, startup_state, core_interaction_config_guard)
                  )

                maybe_emit_summary(failure, options)
                {:error, failure}
            end

          {:error, reason} ->
            shutdown_state =
              case run_bounded(:shutdown, timeout_ms, fn ->
                     runtime_application.shutdown(runtime, timeout_ms: timeout_ms)
                   end) do
                state when is_map(state) -> state
                {:error, error} -> %{status: :shutdown_failed, orderly?: false, error: error}
              end

            {:error,
             reason
             |> Map.put(:shutdown, shutdown_state)
             |> Map.put(:healthy?, false)}
        end

      {:error, %{reason: :smoke_test_timeout} = timeout_result} ->
        failure =
          timeout_result
          |> Map.put(:core_interaction_config_guard, core_interaction_config_guard)
          |> Map.put(:checks, startup_timeout_checks(context, core_interaction_config_guard))

        maybe_emit_summary(failure, options)
        {:error, failure}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unhealthy_result(context, reason) do
    {:error,
     %{
       status: :unhealthy,
       healthy?: false,
       mode: :smoke_test,
       reason: reason,
       checked_at_ms: monotonic_ms(),
       context: context
     }}
  end

  defp timeout_result(phase, timeout_ms) when phase in [:startup, :shutdown] do
    %{
      status: :unhealthy,
      healthy?: false,
      mode: :smoke_test,
      reason: :smoke_test_timeout,
      phase: phase,
      timeout_ms: timeout_ms,
      deterministic_failure?: true,
      terminal_native?: true,
      interactive_ui_started?: false,
      event_loop_started?: false,
      checked_at_ms: monotonic_ms()
    }
  end

  defp runtime_context(context, options) do
    options
    |> Map.take([:runtime_session_id, :journal_path])
    |> Map.merge(context)
  end

  defp record_startup_state(runtime, context, core_interaction_config_guard) do
    case Ourocode.Journal.append(runtime.journal.path, %{
           type: :runtime_startup_succeeded,
           runtime_source: :elixir_runtime,
           source: :cli,
           mode: :smoke_test,
           session_id: runtime.session_id,
           occurred_at_ms: System.system_time(:millisecond),
           payload: %{
             project_dir: context.project_dir,
             service_statuses: runtime.service_statuses,
             initialized_services: Enum.sort(Map.keys(runtime.services)),
             event_pipeline: runtime.event_pipeline,
             pane_model: runtime.pane_model,
             focus_state: runtime.focus_state,
             plugins: runtime.plugins,
             commands: runtime.commands,
             queued_notifications: runtime.queued_notifications,
             hooks: runtime.hooks,
             wonder_tool: runtime.wonder_tool,
             core_interaction_config_guard: core_interaction_config_guard
           }
         }) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         %{
           status: :unhealthy,
           healthy?: false,
           reason: :startup_journal_failed,
           details: reason
         }}
    end
  end

  defp startup_state(runtime) do
    journal_entries =
      case Ourocode.Journal.read_ordered(runtime.journal.path) do
        {:ok, entries} -> entries
        {:error, _reason} -> []
      end

    %{
      status: runtime.status,
      healthy?: runtime.healthy?,
      session_id: runtime.session_id,
      services: Enum.sort(Map.keys(runtime.services)),
      service_statuses: runtime.service_statuses,
      journal: Map.put(runtime.journal, :normalized_event_count, length(journal_entries)),
      event_pipeline: runtime.event_pipeline,
      pane_model: runtime.pane_model,
      focus_state: runtime.focus_state,
      plugins: runtime.plugins,
      commands: runtime.commands,
      queued_notifications: runtime.queued_notifications,
      hooks: runtime.hooks,
      wonder_tool: runtime.wonder_tool,
      startup_event: Enum.find(journal_entries, &startup_event_recorded?/1)
    }
  end

  defp checks(context, startup_state, shutdown_state, core_interaction_config_guard) do
    %{
      project_dir_exists?: File.dir?(context.project_dir),
      config_loaded?: is_map(context.config),
      core_interaction_endpoint_free?:
        core_interaction_config_guard.core_interaction_requires_endpoint? == false,
      runtime_initialized?: startup_state.status == :ready,
      runtime_shutdown?: shutdown_state.orderly? == true,
      startup_state_recorded?: startup_event_recorded?(startup_state.startup_event),
      journal_replayable?: startup_state.journal.replayable? == true,
      task_request_accepted?:
        is_nil(Map.get(context, :initial_task_request)) or
          is_binary(context.initial_task_request.task_input)
    }
  end

  defp startup_timeout_checks(context, core_interaction_config_guard) do
    %{
      project_dir_exists?: File.dir?(context.project_dir),
      config_loaded?: is_map(context.config),
      core_interaction_endpoint_free?:
        core_interaction_config_guard.core_interaction_requires_endpoint? == false,
      runtime_initialized?: false,
      runtime_shutdown?: false,
      startup_state_recorded?: false,
      journal_replayable?: false,
      task_request_accepted?:
        is_nil(Map.get(context, :initial_task_request)) or
          is_binary(context.initial_task_request.task_input)
    }
  end

  defp timeout_checks(context, startup_state, core_interaction_config_guard) do
    %{
      project_dir_exists?: File.dir?(context.project_dir),
      config_loaded?: is_map(context.config),
      core_interaction_endpoint_free?:
        core_interaction_config_guard.core_interaction_requires_endpoint? == false,
      runtime_initialized?: startup_state.status == :ready,
      runtime_shutdown?: false,
      startup_state_recorded?: startup_event_recorded?(startup_state.startup_event),
      journal_replayable?: startup_state.journal.replayable? == true,
      task_request_accepted?:
        is_nil(Map.get(context, :initial_task_request)) or
          is_binary(context.initial_task_request.task_input)
    }
  end

  defp maybe_emit_summary(result, %{output: output}) when output != :silent do
    IO.puts(output, "ourocode smoke test: #{summary_status(result)}")
    IO.puts(output, "mode: smoke_test")
    IO.puts(output, "interactive_ui_started?: false")
    result
  end

  defp maybe_emit_summary(result, _options), do: result

  defp startup_event_recorded?(%{type: :runtime_startup_succeeded}), do: true
  defp startup_event_recorded?(%{type: "runtime_startup_succeeded"}), do: true
  defp startup_event_recorded?(%{"type" => "runtime_startup_succeeded"}), do: true
  defp startup_event_recorded?(_event), do: false

  defp smoke_status(%{orderly?: true}), do: :healthy
  defp smoke_status(_shutdown_state), do: :unhealthy

  defp summary_status(%{healthy?: true}), do: "ok"

  defp summary_status(%{reason: :smoke_test_timeout, phase: phase}),
    do: "failed (#{phase} timeout)"

  defp summary_status(_result), do: "failed"

  defp smoke_timeout_ms(options) do
    options
    |> Map.get(:timeout_ms, @default_timeout_ms)
    |> normalize_timeout_ms()
  end

  defp normalize_timeout_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: timeout_ms

  defp normalize_timeout_ms(_timeout_ms), do: @default_timeout_ms

  defp run_bounded(phase, timeout_ms, fun)
       when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    parent = self()
    result_ref = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          catch
            kind, reason -> {:error, %{reason: :smoke_test_failed, kind: kind, details: reason}}
          end

        send(parent, {result_ref, self(), result})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, %{reason: :smoke_test_failed, phase: phase, details: reason}}

      {^result_ref, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          0 -> :ok
        end

        {:error, timeout_result(phase, timeout_ms)}
    end
  end

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end
end
