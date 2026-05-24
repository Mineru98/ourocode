defmodule Ourocode.Runtime.ApplicationServicesTest do
  use ExUnit.Case, async: false

  alias Ourocode.Runtime.ApplicationServices
  alias Ourocode.Runtime.ApplicationState

  test "builds one child spec for each runtime service id" do
    context = context("application-services-child-spec-test")

    child_ids =
      context
      |> ApplicationServices.children(
        File.cwd!(),
        "/tmp/ourocode-application-services-child-spec.jsonl",
        :application_services_child_spec_registry
      )
      |> Enum.map(& &1.id)
      |> Enum.sort()

    assert child_ids == ApplicationState.service_ids() |> Enum.sort()
  end

  test "starts supervised runtime services and reports their pids" do
    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-application-services-#{unique_id()}.jsonl")

    assert {:ok, supervisor_pid, services, registry_name} =
             ApplicationServices.start(
               context("application-services-start-test"),
               File.cwd!(),
               journal_path
             )

    on_exit(fn ->
      if Process.alive?(supervisor_pid), do: Supervisor.stop(supervisor_pid)
      File.rm(journal_path)
    end)

    assert is_pid(supervisor_pid)
    assert is_atom(registry_name)
    assert Enum.sort(Map.keys(services)) == ApplicationState.service_ids() |> Enum.sort()
    assert Enum.all?(services, fn {_service_id, pid} -> Process.alive?(pid) end)
    assert ApplicationServices.service_pids(supervisor_pid) == services
  end

  defp context(session_id) do
    %{
      config: Ourocode.Config.defaults(),
      runtime_session_id: session_id,
      plugin_config_watcher_poll_interval_ms: false
    }
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end
end
