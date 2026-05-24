defmodule Ourocode.Runtime.ApplicationShutdownTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.ApplicationShutdown

  test "shutdown stops supervisor and reports released services" do
    {:ok, supervisor_pid} =
      Supervisor.start_link(
        [%{id: :service, start: {Agent, :start_link, [fn -> :ready end]}}],
        strategy: :one_for_one
      )

    [{:service, service_pid, :worker, [Agent]}] = Supervisor.which_children(supervisor_pid)

    report =
      ApplicationShutdown.shutdown(
        %{supervisor_pid: supervisor_pid, services: %{service: service_pid}},
        timeout_ms: 20
      )

    assert report.status == :shutdown_complete
    assert report.orderly?
    assert report.supervisor_alive_before?
    assert report.supervisor_stopped?
    assert report.service_count == 1
    assert report.services_stopped?
    assert report.released_service_ids == [:service]
    assert report.leaked_service_ids == []
  end

  test "shutdown skips malformed runtimes" do
    assert %{
             status: :shutdown_skipped,
             orderly?: true,
             service_count: 0,
             released_service_ids: []
           } = ApplicationShutdown.shutdown(%{})
  end
end
