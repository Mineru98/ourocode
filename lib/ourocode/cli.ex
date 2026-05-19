defmodule Ourocode.CLI do
  @moduledoc """
  Minimal CLI startup boundary for ourocode.

  Startup resolves the implementation project directory before later runtime
  supervision, transport, journal, and pane systems are attached.
  """

  alias Ourocode.CLI.StartupArgs
  alias Ourocode.CLI.SmokeTest
  alias Ourocode.Terminal.EventLoop
  alias Ourocode.Terminal.ShellRenderer

  @doc """
  Escript entry point.
  """
  def main(args) do
    launch(args, Ourocode.Terminal.Application)
  end

  @doc """
  Launches the terminal application and keeps its input loop alive.
  """
  def launch(args, terminal_application, options \\ []) do
    if "--detect" in args do
      print_detection()
    else
      result = main(args, terminal_application)
      run_launch_flow(result, options)
    end
  end

  @doc false
  # Non-interactive backend probe (single source: Model.Catalog), used by
  # install.sh to report what `/model` will offer, mirroring how the
  # Ouroboros installer detects available runtimes.
  def print_detection do
    models = Ourocode.Model.Catalog.list()
    default = Ourocode.Model.Catalog.default()

    IO.puts("ourocode detected backends:")

    Enum.each(models, fn m ->
      status =
        case m.status do
          :ready -> "ready"
          {:needs_auth, hint} -> "sign in  (#{hint})"
          :unavailable -> "not installed"
        end

      mark = if m.id == default.id, do: "*", else: " "
      IO.puts("  #{mark} #{String.pad_trailing(m.label, 22)} #{status}")
    end)

    IO.puts("")
    IO.puts("default: #{default.label}  (switch anytime with /model)")
    {:ok, %{detected: Enum.map(models, & &1.id), default: default.id}}
  end

  def main(args, terminal_application) do
    with {:ok, startup_args} <- StartupArgs.parse(args),
         {:ok, project_dir} <- resolve_project_dir(startup_args.project_dir),
         {:ok, config} <- Ourocode.Config.load(project_dir, startup_args.config_args) do
      context =
        project_dir
        |> project_context(config)
        |> Map.put(:initial_task_request, startup_args.task_request)

      if smoke_test_requested?(startup_args) do
        SmokeTest.run(context, output: :silent)
      else
        invoke_bootstrap(terminal_application, context)
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, "ourocode startup failed: #{format_startup_error(reason)}")
        System.halt(1)
    end
  end

  @doc """
  Resolves the implementation project directory required by the launcher.
  """
  def resolve_project_dir(path \\ StartupArgs.default_project_dir()) when is_binary(path) do
    project_dir = Path.expand(path)

    if File.dir?(project_dir) do
      {:ok, project_dir}
    else
      {:error, "project directory does not exist: #{project_dir}"}
    end
  end

  @doc """
  Builds the startup project context passed into the dashboard initializer.
  """
  def project_context(project_dir, config \\ Ourocode.Config.defaults())
      when is_binary(project_dir) do
    %{
      project_dir: Path.expand(project_dir),
      cwd: File.cwd!(),
      config: config
    }
  end

  defp run_launch_flow({:ok, %{mode: :smoke_test} = result}, options) do
    options = Map.new(options)
    output = Map.get(options, :output, :stdio)

    if output != :silent do
      IO.puts(output, "ourocode smoke test: ok")
      IO.puts(output, "mode: smoke_test")
      IO.puts(output, "interactive_ui_started?: false")
    end

    {:ok, result}
  end

  defp run_launch_flow({:ok, %{status: :healthy} = result}, options) do
    result = maybe_apply_initial_task(result)
    options = Map.new(options)
    {result, options} = attach_loop_bindings(result, options)

    {loop_result, daemon} =
      if Ourocode.Terminal.Tui.interactive?(options) do
        # Interactive only: ooo workflows assume a reachable Ouroboros MCP
        # server, so bring one up tied to this process. Non-interactive,
        # smoke and piped paths never spawn it.
        {:ok, daemon} = Ourocode.Runtime.McpDaemon.maybe_start()
        {Ourocode.Terminal.Tui.run(result, options, &EventLoop.run/2), daemon}
      else
        output = Map.get(options, :output, :stdio)
        ShellRenderer.draw_initial_frame(result, output)
        {EventLoop.run(result, options), nil}
      end

    case loop_result do
      {:ok, event_loop} ->
        stop_all(result, daemon)
        {:ok, Map.put(result, :event_loop, event_loop)}

      {:error, _reason} = error ->
        stop_all(result, daemon)
        error
    end
  end

  defp run_launch_flow(result, _options), do: result

  defp stop_all(result, daemon) do
    Ourocode.Runtime.McpDaemon.stop(daemon)
    stop_runtime(result)
  end

  # Wires the real runtime MCP pipeline into the prompt loop. Caller-supplied
  # options (tests, embedders) win over bindings so non-interactive, smoke, and
  # piped paths stay unchanged. A degraded result without a runtime is skipped.
  defp attach_loop_bindings(result, options) do
    case Ourocode.Runtime.LoopBindings.attach(result) do
      {:ok, agent, binding_options} ->
        merged = Map.merge(Map.new(binding_options), options)

        result =
          result
          |> Map.put(:pane_snapshot, fn ->
            Ourocode.Runtime.LoopBindings.pane_snapshot(agent)
          end)
          |> Map.put(:wonder_answer, fn selection ->
            Ourocode.Runtime.LoopBindings.answer_wonder(agent, selection)
          end)
          |> Map.put(:wonder_cancel, fn reason ->
            Ourocode.Runtime.LoopBindings.cancel_wonder(agent, reason)
          end)
          |> Map.put(:interview_answer, fn text ->
            Ourocode.Runtime.LoopBindings.answer_interview(agent, text)
          end)
          |> Map.put(:wonder_pause, fn ->
            Ourocode.Runtime.LoopBindings.pause_wonder(agent)
          end)
          |> Map.put(:wonder_resume, fn ->
            Ourocode.Runtime.LoopBindings.resume_wonder(agent)
          end)

        {result, merged}

      :skip ->
        {result, options}
    end
  end

  defp format_startup_error(reason) when is_binary(reason), do: reason
  defp format_startup_error(reason), do: inspect(reason)

  defp invoke_bootstrap(terminal_application, context) do
    with {:module, ^terminal_application} <- Code.ensure_loaded(terminal_application) do
      cond do
        function_exported?(terminal_application, :bootstrap, 1) ->
          terminal_application.bootstrap(context)

        function_exported?(terminal_application, :init, 1) ->
          terminal_application.init(context)

        true ->
          {:error, "terminal application must export bootstrap/1 or init/1"}
      end
    else
      {:error, reason} ->
        {:error, "terminal application could not be loaded: #{inspect(reason)}"}
    end
  end

  defp maybe_apply_initial_task(
         %{context: %{initial_task_request: %{task_input: task_input}}} = result
       )
       when is_binary(task_input) do
    update_in(result, [:panes, :task_prompt], fn prompt ->
      %{prompt | value: task_input, cursor_position: String.length(task_input)}
    end)
  end

  defp maybe_apply_initial_task(result), do: result

  defp stop_runtime(%{runtime: runtime}), do: Ourocode.Runtime.Application.stop(runtime)
  defp stop_runtime(_result), do: :ok

  defp smoke_test_requested?(%{smoke_test?: true}), do: true

  defp smoke_test_requested?(_startup_args) do
    Application.get_env(:ourocode, :smoke_test, false) == true or
      Application.get_env(:ourocode, :startup_mode) == :smoke_test
  end
end
