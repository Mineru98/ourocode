defmodule Ourocode.Runtime.ApplicationShutdown do
  @moduledoc false

  @spec stop(map()) :: :ok
  def stop(%{supervisor_pid: supervisor_pid}) when is_pid(supervisor_pid) do
    if Process.alive?(supervisor_pid), do: Supervisor.stop(supervisor_pid)
    :ok
  end

  def stop(_runtime), do: :ok

  @spec shutdown(map(), keyword() | map()) :: map()
  def shutdown(runtime, options \\ [])

  def shutdown(%{supervisor_pid: supervisor_pid, services: services} = runtime, options)
      when is_pid(supervisor_pid) and is_map(services) do
    options = Map.new(options)
    timeout_ms = Map.get(options, :timeout_ms, 1_000)
    service_pids = Map.to_list(services)
    supervisor_alive_before? = Process.alive?(supervisor_pid)

    stop(runtime)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_process_exit([supervisor_pid | Enum.map(service_pids, &elem(&1, 1))], deadline)

    leaked_services =
      service_pids
      |> Enum.filter(fn {_id, pid} -> Process.alive?(pid) end)
      |> Enum.map(fn {id, _pid} -> id end)
      |> Enum.sort()

    supervisor_alive_after? = Process.alive?(supervisor_pid)

    %{
      status:
        if(supervisor_alive_after? or leaked_services != [],
          do: :shutdown_incomplete,
          else: :shutdown_complete
        ),
      orderly?: not supervisor_alive_after? and leaked_services == [],
      supervisor_alive_before?: supervisor_alive_before?,
      supervisor_stopped?: not supervisor_alive_after?,
      service_count: map_size(services),
      services_stopped?: leaked_services == [],
      released_service_ids: services |> Map.keys() |> Enum.sort(),
      leaked_service_ids: leaked_services,
      checked_at_ms: System.monotonic_time(:millisecond)
    }
  end

  def shutdown(runtime, _options) do
    stop(runtime)

    %{
      status: :shutdown_skipped,
      orderly?: true,
      supervisor_alive_before?: false,
      supervisor_stopped?: true,
      service_count: 0,
      services_stopped?: true,
      released_service_ids: [],
      leaked_service_ids: [],
      checked_at_ms: System.monotonic_time(:millisecond)
    }
  end

  defp wait_for_process_exit(pids, deadline) do
    if Enum.any?(pids, &Process.alive?/1) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      wait_for_process_exit(pids, deadline)
    else
      :ok
    end
  end
end
