defmodule Ourocode.Terminal.InterviewLiveState do
  @moduledoc """
  Reads interview-related values from a render result and its live pane snapshot.
  """

  alias Ourocode.Terminal.LiveResult

  @spec result(map()) :: map()
  def result(result), do: LiveResult.result(result)

  @spec interview(map()) :: map() | nil
  def interview(result) do
    case Map.get(result(result), :interview) do
      %{} = interview -> interview
      _other -> nil
    end
  end

  @spec wonder_tool(map()) :: map() | nil
  def wonder_tool(result) do
    case Map.get(result(result), :wonder_tool) do
      %{} = detection -> detection
      _other -> nil
    end
  end

  @spec interview_session(map()) :: map() | nil
  def interview_session(result) do
    case Map.get(result(result), :interview_session) do
      %{} = session -> session
      _other -> nil
    end
  end

  @spec paused?(map()) :: boolean()
  def paused?(result), do: Map.get(result(result), :paused, false) == true
end
