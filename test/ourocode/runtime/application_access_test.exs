defmodule Ourocode.Runtime.ApplicationAccessTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.ApplicationAccess
  alias Ourocode.Runtime.ApplicationState

  test "focus_pane updates supervised focus state through pane model and focus agents" do
    {:ok, pane_pid} = Agent.start_link(fn -> ApplicationState.pane_model_state() end)
    {:ok, focus_pid} = Agent.start_link(fn -> ApplicationState.focus_state() end)

    on_exit(fn ->
      stop_agent(pane_pid)
      stop_agent(focus_pid)
    end)

    runtime = %{services: %{pane_model: pane_pid, focus_state: focus_pid}}

    assert {:ok, result} = ApplicationAccess.focus_pane(runtime, :children, occurred_at_ms: 7)
    assert result.focus_state.focused_pane == :children
    assert result.event.focused_pane == :children

    assert {:ok, current} = ApplicationAccess.current_focus_state(runtime)
    assert current == result.focus_state
  end

  test "current_focused_child_session resolves the focused child from supervised state" do
    child_pane_id = "child-session:access-bravo"

    pane_model =
      ApplicationState.pane_model_state()
      |> Map.update!(:panes, fn panes ->
        Map.put(panes, child_pane_id, %{
          id: child_pane_id,
          kind: :child_session,
          child_id: "access-bravo",
          parent_call_id: "parent-access-bravo"
        })
      end)
      |> Map.update!(:open, &(&1 ++ [child_pane_id]))

    {:ok, pane_pid} = Agent.start_link(fn -> pane_model end)
    {:ok, focus_pid} = Agent.start_link(fn -> ApplicationState.focus_state() end)

    on_exit(fn ->
      stop_agent(pane_pid)
      stop_agent(focus_pid)
    end)

    runtime = %{services: %{pane_model: pane_pid, focus_state: focus_pid}}

    assert {:ok, _result} = ApplicationAccess.focus_pane(runtime, child_pane_id, [])

    assert {:ok, focused_child} = ApplicationAccess.current_focused_child_session(runtime)
    assert focused_child.pane_id == child_pane_id
    assert focused_child.session_id == "access-bravo"
    assert focused_child.pane.parent_call_id == "parent-access-bravo"
  end

  test "registry accessors read supervised registry agents" do
    command_registry = %{entries: %{"/help" => %{slash: "/help"}}}
    plugin_registry = %{status: :ready, enabled_plugins: ["ouroboros"]}

    {:ok, command_pid} = Agent.start_link(fn -> command_registry end)
    {:ok, plugin_pid} = Agent.start_link(fn -> plugin_registry end)

    on_exit(fn ->
      stop_agent(command_pid)
      stop_agent(plugin_pid)
    end)

    runtime = %{services: %{command_registry: command_pid, plugin_registry: plugin_pid}}

    assert ApplicationAccess.current_command_registry(runtime) == {:ok, command_registry}
    assert ApplicationAccess.current_plugin_registry(runtime) == {:ok, plugin_registry}
  end

  test "accessors report unavailable services without raising" do
    assert ApplicationAccess.focus_pane(%{}, :children, []) ==
             {:error, {:unknown_pane, :children}}

    assert ApplicationAccess.current_focus_state(%{}) == {:error, :focus_state_unavailable}

    assert ApplicationAccess.current_focused_child_session(%{}) ==
             {:error, :focus_state_unavailable}

    assert ApplicationAccess.current_command_registry(%{}) ==
             {:error, :command_registry_unavailable}

    assert ApplicationAccess.current_plugin_registry(%{}) ==
             {:error, :plugin_registry_unavailable}
  end

  defp stop_agent(pid) do
    if Process.alive?(pid) do
      Agent.stop(pid)
    end
  catch
    :exit, _reason -> :ok
  end
end
