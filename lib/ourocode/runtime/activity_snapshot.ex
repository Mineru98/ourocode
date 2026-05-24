defmodule Ourocode.Runtime.ActivitySnapshot do
  @moduledoc """
  Refresh helpers for the live Ouroboros activity and reasoning panes.
  """

  alias Ourocode.Runtime.ActivityLine

  @spec refresh_activity(map(), [term()], map(), map(), pos_integer()) :: map()
  def refresh_activity(state, lines, offsets, activity_context, keep)
      when is_map(state) and is_list(lines) and is_map(offsets) and is_integer(keep) do
    activity =
      (Map.get(state, :ouroboros_activity, []) ++ lines)
      |> Enum.map(&ActivityLine.enrich(&1, activity_context))
      |> ActivityLine.dedupe()
      |> Enum.take(-keep)

    interview =
      case state.interview do
        %{} = iv when activity != [] -> Map.put(iv, :mcp_activity, activity)
        other -> other
      end

    %{state | ouroboros_log_offsets: offsets, ouroboros_activity: activity, interview: interview}
  end

  @spec refresh_session_reasoning(map(), [term()], map()) :: map()
  def refresh_session_reasoning(state, [], _reasoning_state), do: state

  def refresh_session_reasoning(state, lines, reasoning_state)
      when is_map(state) and is_list(lines) do
    interview =
      case state.interview do
        %{} = iv ->
          if Map.get(iv, :mcp_reasoning, []) == [] do
            iv
            |> Map.put(:mcp_reasoning, lines)
            |> maybe_put(:mcp_reasoning_state, reasoning_state)
          else
            iv
          end

        other ->
          other
      end

    %{state | interview: interview}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
