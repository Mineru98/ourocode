defmodule Ourocode.Runtime.McpDaemon.ProcessTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.McpDaemon.Process, as: DaemonProcess

  test "spawn_plan redirects daemon output to a per-port log without shell quoting args" do
    plan =
      DaemonProcess.spawn_plan(
        "/bin/ouroboros",
        ["mcp", "serve", "--port", "4321"],
        4321,
        "/bin/sh"
      )

    assert plan.shell == "/bin/sh"
    assert plan.log_path == Path.join(System.tmp_dir!(), "ourocode-mcp-4321.log")

    assert plan.args == [
             "-c",
             "exec \"$0\" \"$@\" >\"#{plan.log_path}\" 2>&1",
             "/bin/ouroboros",
             "mcp",
             "serve",
             "--port",
             "4321"
           ]
  end

  test "stop is a safe no-op for non-spawned handles" do
    assert :ok == DaemonProcess.stop(nil)
    assert :ok == DaemonProcess.stop(%{mode: :external, url: "http://x/mcp"})
    assert :ok == DaemonProcess.stop(%{mode: :disabled, url: "http://x/mcp"})
  end

  test "stop reaps a spawned OS process" do
    erl_port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :hide,
        args: ["-c", "exec sleep 30"]
      ])

    {:os_pid, os_pid} = Port.info(erl_port, :os_pid)
    assert {_out, 0} = System.cmd("kill", ["-0", Integer.to_string(os_pid)])

    assert :ok == DaemonProcess.stop(%{mode: :spawned, port: erl_port, os_pid: os_pid, url: "u"})

    Process.sleep(150)

    assert {_err, code} =
             System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    assert code != 0
  end
end
