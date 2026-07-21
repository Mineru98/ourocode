ExUnit.start()

defmodule Ourocode.Test.PathAssertions do
  @moduledoc false

  import ExUnit.Assertions

  def assert_same_path(left, right) do
    assert path_key(left) == path_key(right)
  end

  def path_key(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> maybe_downcase_windows_path()
  end

  defp maybe_downcase_windows_path(path) do
    case :os.type() do
      {:win32, _name} -> String.downcase(path)
      _other -> path
    end
  end
end

defmodule Ourocode.Test.PortPrograms do
  @moduledoc false

  import ExUnit.Assertions

  def long_running_command do
    erl = System.find_executable("erl") || System.find_executable("erl.exe")
    assert is_binary(erl), "expected erl executable for portable long-running port test helper"

    {erl, ["-noshell", "-eval", "timer:sleep(infinity)."]}
  end

  def echo_line_command(prefix) when is_binary(prefix) do
    elixir_program("""
    IO.stream(:stdio, :line)
    |> Enum.each(fn line ->
      line = line |> String.trim_trailing("\\n") |> String.trim_trailing("\\r")
      IO.puts(#{inspect(prefix)} <> line)
    end)
    """)
  end

  def read_once_and_exit_command do
    elixir_program("""
    IO.read(:stdio, :line)
    System.halt(0)
    """)
  end

  def shell_script(script) when is_binary(script) do
    operations =
      script
      |> normalize_printf_newlines()
      |> String.split("\n")
      |> Enum.flat_map(&parse_shell_line/1)

    elixir_program("""
    operations = #{inspect(operations, limit: :infinity, printable_limit: :infinity)}

    IO.stream(:stdio, :line)
    |> Enum.each(fn line ->
      line = line |> String.trim_trailing("\\n") |> String.trim_trailing("\\r")

      Enum.each(operations, fn
        {:print, value} -> IO.puts(value)
        {:echo_line, prefix} -> IO.puts(prefix <> line)
        {:sleep, ms} -> Process.sleep(ms)
      end)
    end)
    """)
  end

  defp elixir_program(source) do
    elixir = System.find_executable("elixir") || System.find_executable("elixir.bat")
    assert is_binary(elixir), "expected elixir executable for portable port test helper"

    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-port-program-#{System.unique_integer([:positive])}.exs"
      )

    File.write!(path, "File.rm(__ENV__.file)\n" <> source)

    {elixir, [path]}
  end

  defp normalize_printf_newlines(script) do
    String.replace(script, "%s\n'", "%s\\n'")
  end

  defp parse_shell_line(raw_line) do
    line = String.trim(raw_line)

    cond do
      line == "" ->
        []

      line == "done" ->
        []

      String.starts_with?(line, "while ") ->
        []

      String.starts_with?(line, "IFS=") ->
        []

      line == "exit 0" ->
        []

      line == "sleep 1" ->
        [{:sleep, 1_000}]

      line == ~s(printf '%s\\n' "echo:$line") ->
        [{:echo_line, "echo:"}]

      match = Regex.run(~r/^printf '%s\\n' '(.*)'$/, line) ->
        [_full, value] = match
        [{:print, value}]

      true ->
        flunk("unsupported portable shell test line: #{inspect(line)}")
    end
  end
end

defmodule Ourocode.Test.OsProcessAssertions do
  @moduledoc false

  import ExUnit.Assertions

  def assert_os_process_alive(os_pid) do
    assert os_process_alive?(os_pid), "expected OS process #{os_pid} to be alive"
  end

  def refute_os_process_alive(os_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_500

    unless wait_until_dead(os_pid, deadline) do
      flunk("expected OS process #{os_pid} to be reaped")
    end
  end

  defp wait_until_dead(os_pid, deadline) do
    cond do
      not os_process_alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(25)
        wait_until_dead(os_pid, deadline)
    end
  end

  defp os_process_alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    if windows?() do
      tasklist_contains_pid?(os_pid)
    else
      {_output, code} =
        System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

      code == 0
    end
  end

  defp tasklist_contains_pid?(os_pid) do
    command = System.find_executable("tasklist") || "tasklist"

    {output, _code} =
      System.cmd(command, ["/FI", "PID eq #{os_pid}", "/NH"], stderr_to_stdout: true)

    output
    |> String.split()
    |> Enum.member?(Integer.to_string(os_pid))
  end

  defp windows?, do: match?({:win32, _name}, :os.type())
end
