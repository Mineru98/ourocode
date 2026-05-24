defmodule Ourocode.Runtime.LoopBindingEventFlow do
  @moduledoc """
  Runtime event inbox and live pane folding for loop bindings.
  """

  alias Ourocode.Dashboard.{ChildSessionPanes, ParentMcpPane}
  alias Ourocode.Runtime.{InterviewState, WonderDetection}

  @spec enqueue(pid(), map()) :: :ok
  def enqueue(agent, event) when is_pid(agent) and is_map(event) do
    Agent.update(agent, fn state ->
      state
      |> Map.update!(:inbox, &:queue.in(event, &1))
      |> fold_event(event)
    end)
  end

  @spec poll_fun(pid()) :: (map() -> {:ok, map()} | {:none, map()})
  def poll_fun(agent) when is_pid(agent) do
    fn _state ->
      Agent.get_and_update(agent, fn state ->
        case :queue.out(state.inbox) do
          {{:value, event}, rest} -> {{:ok, event}, %{state | inbox: rest}}
          {:empty, _inbox} -> {:none, state}
        end
      end)
    end
  end

  @spec runtime_event_fun(pid()) :: (map(), map() -> :ok)
  def runtime_event_fun(_agent) do
    fn _runtime_event, _startup_result -> :ok end
  end

  @spec fold_event(map(), map()) :: map()
  def fold_event(state, event) do
    state
    |> Map.update!(:parent, &safe_apply(ParentMcpPane, &1, event))
    |> Map.update!(:child, &safe_apply(ChildSessionPanes, &1, event))
    |> WonderDetection.apply(event)
    |> InterviewState.detect(event)
  end

  defp safe_apply(module, pane_state, event) do
    module.apply_event(pane_state, event)
  rescue
    _exception -> pane_state
  end
end
