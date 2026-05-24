defmodule Ourocode.Runtime.EventRouter do
  @moduledoc """
  Routes normalized runtime events through journal, event pipeline, and hook state.
  """

  alias Ourocode.Journal
  alias Ourocode.Journal.SourceTransportNormalizer
  alias Ourocode.Runtime.HookLifecycle

  @spec route(map(), map(), keyword() | map()) :: {:ok, map()} | {:error, map()}
  def route(runtime, source_event, options \\ [])

  def route(
        %{
          services: %{event_pipeline: event_pipeline_pid, hook_lifecycle: hook_lifecycle_pid},
          journal: %{path: journal_path}
        },
        source_event,
        options
      )
      when is_pid(event_pipeline_pid) and is_pid(hook_lifecycle_pid) and is_binary(journal_path) do
    context = route_event_context(event_pipeline_pid, options)

    with {:ok, events, _report} <-
           SourceTransportNormalizer.normalize([source_event], context: context),
         :ok <- append_journaled_events(journal_path, events) do
      event_pipeline = update_event_pipeline(event_pipeline_pid, events)
      hooks = update_hook_lifecycle(hook_lifecycle_pid, events)

      {:ok,
       %{
         events: events,
         event_pipeline: event_pipeline,
         hooks: hooks,
         journal_path: journal_path
       }}
    else
      {:error, reason} when is_map(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, %{status: :failed, reason: reason}}
    end
  end

  def route(_runtime, _source_event, _options) do
    {:error, %{status: :failed, reason: :runtime_event_pipeline_unavailable}}
  end

  defp route_event_context(event_pipeline_pid, options) do
    options = Map.new(options)

    event_seq =
      Agent.get(event_pipeline_pid, fn event_pipeline ->
        Map.get(event_pipeline, :normalized_event_seq, 0) + 1
      end)

    %{
      event_seq: event_seq,
      parent_call_id: Map.get(options, :parent_call_id, "runtime-event-pipeline"),
      runtime_source: Map.get(options, :runtime_source, "terminal-runtime"),
      external_ids: Map.get(options, :external_ids, %{})
    }
    |> Map.merge(Map.get(options, :context, %{}))
  end

  defp append_journaled_events(journal_path, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case Journal.append(journal_path, event) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_event_pipeline(event_pipeline_pid, events) do
    Agent.get_and_update(event_pipeline_pid, fn event_pipeline ->
      updated =
        event_pipeline
        |> Map.update(:events, events, &(&1 ++ events))
        |> Map.update!(:normalized_event_count, &(&1 + length(events)))
        |> Map.put(:normalized_event_seq, HookLifecycle.latest_event_seq(events, event_pipeline))

      {updated, updated}
    end)
  end

  defp update_hook_lifecycle(hook_lifecycle_pid, events) do
    Agent.get_and_update(hook_lifecycle_pid, fn hook_lifecycle ->
      updated = HookLifecycle.apply_events(hook_lifecycle, events)
      {updated, updated}
    end)
  end
end
