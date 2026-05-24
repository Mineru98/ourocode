defmodule Ourocode.Runtime.McpDaemon.Process do
  @moduledoc """
  OS process boundary for the local Ouroboros MCP daemon.
  """

  alias Ourocode.Runtime.McpDaemon.Command

  @type spawn_result ::
          {:ok, port(), non_neg_integer() | nil, Path.t()}
          | :unavailable

  @spec spawn_server(String.t(), :inet.port_number(), term()) :: spawn_result()
  def spawn_server(host, port, llm_backend) do
    case Command.build(host, port, llm_backend) do
      {exe, args} ->
        plan = spawn_plan(exe, args, port)

        erl_port =
          Port.open({:spawn_executable, plan.shell}, [
            :binary,
            :exit_status,
            :hide,
            args: plan.args
          ])

        os_pid =
          case Port.info(erl_port, :os_pid) do
            {:os_pid, pid} -> pid
            _none -> nil
          end

        {:ok, erl_port, os_pid, plan.log_path}

      :none ->
        :unavailable
    end
  end

  @doc false
  @spec spawn_plan(String.t(), [String.t()], :inet.port_number(), String.t() | nil) :: map()
  def spawn_plan(exe, args, port, shell \\ nil)
      when is_binary(exe) and is_list(args) and is_integer(port) do
    shell = shell || System.find_executable("sh") || "/bin/sh"
    log_path = Path.join(System.tmp_dir!(), "ourocode-mcp-#{port}.log")

    %{
      shell: shell,
      args: ["-c", "exec \"$0\" \"$@\" >\"#{log_path}\" 2>&1", exe] ++ args,
      log_path: log_path
    }
  end

  @spec stop(map() | nil) :: :ok
  def stop(%{mode: :spawned} = handle) do
    case Map.get(handle, :os_pid) do
      pid when is_integer(pid) and pid > 0 ->
        System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

      _none ->
        :ok
    end

    erl_port = Map.get(handle, :port)
    if is_port(erl_port) and Port.info(erl_port) != nil, do: Port.close(erl_port)
    :ok
  rescue
    _exception -> :ok
  end

  def stop(_handle), do: :ok
end
