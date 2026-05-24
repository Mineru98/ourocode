defmodule Ourocode.Terminal.FooterStateArea do
  @moduledoc """
  Terminal-native footer state area projection.

  The footer keeps persistent runtime state visible below the prompt without
  owning session state itself. It is intentionally data-only so the render model
  can be journaled and replayed by the Elixir runtime.
  """

  alias Ourocode.Terminal.{
    FooterHookActivity,
    FooterRuntimeState,
    QueuedNotificationState
  }

  @default_title "State"
  @width 80
  @height 6
  @y 33

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
    runtime_state = FooterRuntimeState.project(startup_result, context, runtime)

    %{
      id: :footer_state,
      kind: :terminal_footer_state_area,
      title: @default_title,
      ui_surface:
        Map.get(startup_result, :ui_surface) || Map.get(context, :ui_surface, :terminal),
      focus: focused_pane(panes),
      layout_mode: layout_mode(panes),
      runtime_status: runtime_state.runtime_status,
      stream_status: runtime_state.stream_status,
      journal_status: runtime_state.journal_status,
      queued_count:
        startup_result
        |> QueuedNotificationState.from_startup_result()
        |> QueuedNotificationState.pending_count(),
      transport_statuses: runtime_state.transport_statuses,
      replayable?: runtime_state.replayable?,
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
      "| queued=#{area.queued_count} replayable?=#{area.replayable?} transports=#{FooterRuntimeState.transport_text(area.transport_statuses)}",
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

  defp hook_activity(startup_result, context, runtime) do
    FooterHookActivity.from_states([runtime, context, startup_result])
  end

  defp hook_activity_text(%{state: :running} = activity) do
    "| hooks=running activity=#{inspect(activity.summary)} hook_id=#{activity.hook_id} events=#{activity.event_count}"
  end

  defp hook_activity_text(%{state: :idle} = activity) do
    "| hooks=idle events=#{activity.event_count}"
  end

  defp hook_activity_text(_activity), do: "| hooks=idle events=0"
end
