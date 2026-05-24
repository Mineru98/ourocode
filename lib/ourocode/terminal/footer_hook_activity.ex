defmodule Ourocode.Terminal.FooterHookActivity do
  @moduledoc """
  Summarizes hook lifecycle state for the terminal footer.
  """

  @hook_summary_limit 60

  @type t :: %{
          required(:state) => :running | :idle,
          required(:summary) => String.t(),
          required(:hook_id) => String.t() | nil,
          required(:hook_event) => String.t() | nil,
          required(:event_count) => non_neg_integer()
        }

  @spec from_states([map()]) :: t()
  def from_states(states) when is_list(states) do
    states
    |> Enum.find_value(&hook_lifecycle_state/1)
    |> case do
      nil -> idle()
      hook_lifecycle -> derive(hook_lifecycle)
    end
  end

  @spec idle() :: t()
  def idle do
    %{state: :idle, summary: "idle", hook_id: nil, hook_event: nil, event_count: 0}
  end

  defp hook_lifecycle_state(%{hook_lifecycle: hook_lifecycle}) when is_map(hook_lifecycle),
    do: hook_lifecycle

  defp hook_lifecycle_state(%{"hook_lifecycle" => hook_lifecycle}) when is_map(hook_lifecycle),
    do: hook_lifecycle

  defp hook_lifecycle_state(%{hooks: hook_lifecycle}) when is_map(hook_lifecycle),
    do: hook_lifecycle

  defp hook_lifecycle_state(%{"hooks" => hook_lifecycle}) when is_map(hook_lifecycle),
    do: hook_lifecycle

  defp hook_lifecycle_state(_state), do: nil

  defp derive(hook_lifecycle) do
    active = latest_event([:latest_progress, :latest_started], hook_lifecycle)
    done = latest_event([:latest_response, :latest_completed], hook_lifecycle)
    count = hook_event_count(hook_lifecycle)

    if active && (is_nil(done) or hook_seq(active) > hook_seq(done)) do
      hook_event = hook_event_name(active)
      hook_id = hook_field(active, :hook_id)

      %{
        state: :running,
        summary: "Running #{hook_event} hook",
        hook_id: hook_id,
        hook_event: hook_event,
        event_count: count
      }
    else
      %{idle() | event_count: count}
    end
  end

  defp latest_event(keys, hook_lifecycle) do
    keys
    |> Enum.map(&(Map.get(hook_lifecycle, &1) || Map.get(hook_lifecycle, to_string(&1))))
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&hook_seq/1, fn -> nil end)
  end

  defp hook_seq(event) do
    case hook_field(event, :event_seq) do
      seq when is_integer(seq) -> seq
      _seq -> -1
    end
  end

  defp hook_event_count(hook_lifecycle) do
    case Map.get(hook_lifecycle, :event_count) || Map.get(hook_lifecycle, "event_count") do
      count when is_integer(count) and count >= 0 ->
        count

      _count ->
        case Map.get(hook_lifecycle, :events) || Map.get(hook_lifecycle, "events") do
          events when is_list(events) -> length(events)
          _events -> 0
        end
    end
  end

  defp hook_event_name(event) do
    payload = hook_field(event, :payload)

    name =
      (is_map(payload) && (Map.get(payload, "hook") || Map.get(payload, :hook))) ||
        hook_field(event, :hook_event) ||
        hook_field(event, :hook_name) ||
        hook_field(event, :hook_id) ||
        "hook"

    name |> to_string() |> truncate(@hook_summary_limit)
  end

  defp hook_field(event, key) when is_map(event) do
    Map.get(event, key) || Map.get(event, to_string(key))
  end

  defp hook_field(_event, _key), do: nil

  defp truncate(value, limit) when byte_size(value) > limit do
    String.slice(value, 0, limit)
  end

  defp truncate(value, _limit), do: value
end
