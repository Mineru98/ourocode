defmodule Ourocode.Terminal.FooterStateArea do
  @moduledoc """
  Terminal-native footer state area projection.

  The footer keeps persistent runtime state visible below the prompt without
  owning session state itself. It is intentionally data-only so the render model
  can be journaled and replayed by the Elixir runtime.
  """

  @default_title "State"
  @width 80
  @height 6
  @y 33
  @hook_summary_limit 60

  @type rendered_area :: %{
          required(:id) => :footer_state,
          required(:kind) => :terminal_footer_state_area,
          required(:title) => String.t(),
          required(:ui_surface) => atom() | String.t(),
          required(:focus) => atom() | String.t(),
          required(:layout_mode) => atom() | String.t(),
          required(:runtime_status) => atom() | String.t(),
          required(:stream_status) => atom() | String.t(),
          required(:journal_status) => atom() | String.t(),
          required(:queued_count) => non_neg_integer(),
          required(:transport_statuses) => [String.t()],
          required(:replayable?) => boolean(),
          required(:hook_activity) => %{
            required(:state) => :running | :idle,
            required(:summary) => String.t(),
            required(:hook_id) => String.t() | nil,
            required(:hook_event) => String.t() | nil,
            required(:event_count) => non_neg_integer()
          },
          required(:layout) => map()
        }

  @doc """
  Builds a render-ready footer state area from the current terminal UI model.
  """
  @spec render(map()) :: rendered_area()
  def render(startup_result) when is_map(startup_result) do
    context = Map.get(startup_result, :context, %{})
    runtime = Map.get(startup_result, :runtime) || Map.get(context, :runtime, %{})
    panes = Map.get(startup_result, :panes, %{})

    %{
      id: :footer_state,
      kind: :terminal_footer_state_area,
      title: @default_title,
      ui_surface:
        Map.get(startup_result, :ui_surface) || Map.get(context, :ui_surface, :terminal),
      focus: focused_pane(panes),
      layout_mode: layout_mode(panes),
      runtime_status: status(runtime, :unknown),
      stream_status: stream_status(startup_result, context, runtime),
      journal_status: journal_status(startup_result, context, runtime),
      queued_count: queued_count(startup_result, context, runtime),
      transport_statuses: transport_statuses(startup_result, context, runtime),
      replayable?: replayable?(startup_result, context, runtime),
      hook_activity: hook_activity(startup_result, context, runtime),
      layout: %{
        mode: :terminal_stack,
        region: :footer_state,
        order: 99,
        rect: %{x: 0, y: @y, width: @width, height: @height}
      }
    }
  end

  @doc """
  Renders footer state as compact terminal-safe text.
  """
  @spec render_text(rendered_area() | map()) :: String.t()
  def render_text(%{kind: :terminal_footer_state_area} = area) do
    [
      "+-- #{area.title}",
      "| surface=#{area.ui_surface} focus=#{area.focus} layout=#{area.layout_mode}",
      "| runtime=#{area.runtime_status} stream=#{area.stream_status} journal=#{area.journal_status}",
      "| queued=#{area.queued_count} replayable?=#{area.replayable?} transports=#{transport_text(area.transport_statuses)}",
      hook_activity_text(Map.get(area, :hook_activity)),
      "+--"
    ]
    |> Enum.join("\n")
  end

  def render_text(startup_result) when is_map(startup_result) do
    startup_result
    |> render()
    |> render_text()
  end

  defp focused_pane(%{task_prompt: %{focused?: true}}), do: :task_prompt
  defp focused_pane(%{focused: focused}) when not is_nil(focused), do: focused
  defp focused_pane(_panes), do: :none

  defp layout_mode(%{layout: %{mode: mode}}), do: mode
  defp layout_mode(_panes), do: :unknown

  defp stream_status(startup_result, context, runtime) do
    status(
      Map.get(runtime, :stream) || Map.get(context, :stream) || Map.get(startup_result, :stream),
      :unknown
    )
  end

  defp journal_status(startup_result, context, runtime) do
    status(
      Map.get(runtime, :journal) || Map.get(context, :journal) ||
        Map.get(startup_result, :journal),
      :unknown
    )
  end

  defp status(%{status: status}, _default)
       when (is_atom(status) and not is_nil(status)) or is_binary(status),
       do: status

  defp status(status, _default)
       when (is_atom(status) and not is_nil(status)) or is_binary(status),
       do: status

  defp status(_value, default), do: default

  defp queued_count(startup_result, context, runtime) do
    [startup_result, context, runtime]
    |> Enum.find_value(0, &count_from_queue_state/1)
  end

  defp count_from_queue_state(%{queued_notifications: queue_state}) when is_map(queue_state) do
    case Map.get(queue_state, :pending_count) || Map.get(queue_state, "pending_count") do
      count when is_integer(count) and count >= 0 -> count
      _count -> queue_state |> queue_items() |> Enum.count(&pending?/1)
    end
  end

  defp count_from_queue_state(_state), do: nil

  defp queue_items(queue_state) do
    case Map.get(queue_state, :items) || Map.get(queue_state, "items") do
      items when is_list(items) -> items
      _items -> []
    end
  end

  defp pending?(item) when is_map(item) do
    status = Map.get(item, :status) || Map.get(item, "status")
    status in [nil, :pending, "pending", :queued, "queued"]
  end

  defp pending?(_item), do: false

  defp transport_statuses(startup_result, context, runtime) do
    (transport_entries(startup_result) ++ transport_entries(context) ++ transport_entries(runtime))
    |> Enum.map(&transport_status/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp transport_entries(%{transports: transports}) when is_list(transports), do: transports
  defp transport_entries(%{"transports" => transports}) when is_list(transports), do: transports
  defp transport_entries(_state), do: []

  defp transport_status(%{type: type, status: status}), do: "#{type}:#{status}"
  defp transport_status(%{"type" => type, "status" => status}), do: "#{type}:#{status}"
  defp transport_status(type) when is_atom(type) or is_binary(type), do: "#{type}:unknown"
  defp transport_status(_transport), do: ""

  defp replayable?(startup_result, context, runtime) do
    replayable_value(startup_result) || replayable_value(context) || replayable_value(runtime) ||
      false
  end

  defp replayable_value(%{replayable?: replayable?}) when is_boolean(replayable?), do: replayable?

  defp replayable_value(%{"replayable?" => replayable?}) when is_boolean(replayable?),
    do: replayable?

  defp replayable_value(_state), do: nil

  defp transport_text([]), do: "none"
  defp transport_text(transport_statuses), do: Enum.join(transport_statuses, ",")

  defp hook_activity(startup_result, context, runtime) do
    [runtime, context, startup_result]
    |> Enum.find_value(&hook_lifecycle_state/1)
    |> case do
      nil -> idle_hook_activity()
      hook_lifecycle -> derive_hook_activity(hook_lifecycle)
    end
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

  defp idle_hook_activity do
    %{state: :idle, summary: "idle", hook_id: nil, hook_event: nil, event_count: 0}
  end

  defp derive_hook_activity(hook_lifecycle) do
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
      %{idle_hook_activity() | event_count: count}
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

  defp hook_activity_text(%{state: :running} = activity) do
    "| hooks=running activity=#{inspect(activity.summary)} hook_id=#{activity.hook_id} events=#{activity.event_count}"
  end

  defp hook_activity_text(%{state: :idle} = activity) do
    "| hooks=idle events=#{activity.event_count}"
  end

  defp hook_activity_text(_activity), do: "| hooks=idle events=0"
end
