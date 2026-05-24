defmodule Ourocode.Journal.SourceTransportNormalizer.HookLifecycleEvent do
  @moduledoc """
  Normalizes runtime/plugin hook lifecycle maps into first-class lifecycle events.
  """

  alias Ourocode.MCP.LifecycleEvent

  @spec normalize(map(), map()) :: {:ok, LifecycleEvent.t()} | :error
  def normalize(%{} = event, context) do
    with {:ok, type} <- hook_lifecycle_type(event),
         hook_id when is_binary(hook_id) and hook_id != "" <- event_value(event, :hook_id),
         source when not is_nil(source) <- event_value(event, :source) do
      source = normalize_source(source)

      {:ok,
       LifecycleEvent.new(
         type,
         hook_lifecycle_attrs(type, event, context, hook_id, source)
       )}
    else
      _not_hook_lifecycle -> :error
    end
  end

  def normalize(_event, _context), do: :error

  defp hook_lifecycle_type(event) do
    event
    |> event_value(:type)
    |> normalize_type()
    |> case do
      type when type in [:hook_started, :hook_progress] -> {:ok, type}
      type when type in [:hook_response, :hook_completed] -> {:ok, type}
      _type -> :error
    end
  end

  defp hook_lifecycle_attrs(type, event, context, hook_id, source) do
    base_attrs = %{
      event_seq: Map.fetch!(context, :event_seq),
      transport: normalize_transport(event_value(event, :transport)) || :runtime,
      parent_call_id: parent_call_id(event, context),
      source: source,
      runtime_source: runtime_source(event, context, source),
      external_ids: external_ids(event, context),
      occurred_at_ms: occurred_at_ms(event, context),
      hook_id: hook_id,
      payload: event_value(event, :payload),
      raw_event: event
    }

    case type do
      :hook_progress ->
        base_attrs
        |> Map.put(:progress_state, progress_state(event))
        |> Map.put(:ordering_metadata, ordering_metadata(event))

      type when type in [:hook_response, :hook_completed] ->
        base_attrs
        |> Map.put(:status, completion_status(event))
        |> Map.put(:result, completion_result(event))
        |> Map.put(:error, completion_error(event))
        |> Map.put(:completion_metadata, completion_metadata(event))

      _type ->
        base_attrs
    end
  end

  defp event_value(event, key) when is_atom(key) do
    string_key = Atom.to_string(key)

    case Map.fetch(event, key) do
      {:ok, nil} -> Map.get(event, string_key)
      {:ok, value} -> value
      :error -> Map.get(event, string_key)
    end
  end

  defp normalize_type(:hook_response), do: :hook_response
  defp normalize_type(:plugin_hook_response), do: :hook_response
  defp normalize_type(:runtime_hook_response), do: :hook_response
  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(type) when is_binary(type) do
    case String.trim(type) do
      "hook_started" -> :hook_started
      "hook_progress" -> :hook_progress
      "hook_completed" -> :hook_completed
      "hook_response" -> :hook_response
      "plugin_hook_response" -> :hook_response
      "runtime_hook_response" -> :hook_response
      _type -> nil
    end
  end

  defp normalize_type(_type), do: nil

  defp normalize_source(source) when is_binary(source) do
    case String.trim(source) do
      "plugin_runtime" -> :plugin_runtime
      "runtime" -> :runtime
      "hook_lifecycle" -> :hook_lifecycle
      other -> other
    end
  end

  defp normalize_source(source), do: source

  defp parent_call_id(event, context) do
    event_value(event, :parent_call_id) || Map.fetch!(context, :parent_call_id)
  end

  defp runtime_source(event, context, source) do
    event_value(event, :runtime_source) || to_string(source) ||
      Map.fetch!(context, :runtime_source)
  end

  defp external_ids(event, context) do
    case event_value(event, :external_ids) do
      external_ids when is_map(external_ids) ->
        context
        |> Map.fetch!(:external_ids)
        |> Map.merge(external_ids)

      _external_ids ->
        Map.fetch!(context, :external_ids)
    end
  end

  defp occurred_at_ms(event, context) do
    event_value(event, :occurred_at_ms) ||
      event_value(event, :timestamp_ms) ||
      Map.get(context, :occurred_at_ms, System.system_time(:millisecond))
  end

  defp progress_state(event) do
    event_value(event, :progress_state) ||
      event_value(event, :state) ||
      payload_value(event, :progress_state) ||
      payload_value(event, :state)
  end

  defp ordering_metadata(event) do
    case event_value(event, :ordering_metadata) ||
           event_value(event, :ordering) ||
           event_value(event, :order) ||
           payload_value(event, :ordering_metadata) ||
           payload_value(event, :ordering) ||
           payload_value(event, :order) do
      metadata when is_map(metadata) -> metadata
      _metadata -> %{}
    end
  end

  defp completion_status(event) do
    event_value(event, :status) ||
      payload_value(event, :status) ||
      cond do
        not is_nil(completion_error(event)) -> :error
        not is_nil(completion_result(event)) -> :ok
        true -> :completed
      end
  end

  defp completion_result(event) do
    event_value(event, :result) ||
      payload_value(event, :result)
  end

  defp completion_error(event) do
    event_value(event, :error) ||
      payload_value(event, :error)
  end

  defp completion_metadata(event) do
    case event_value(event, :completion_metadata) ||
           event_value(event, :completion) ||
           event_value(event, :metadata) ||
           payload_value(event, :completion_metadata) ||
           payload_value(event, :completion) ||
           payload_value(event, :metadata) do
      metadata when is_map(metadata) -> metadata
      _metadata -> %{}
    end
  end

  defp payload_value(event, key) do
    case event_value(event, :payload) do
      payload when is_map(payload) -> event_value(payload, key)
      _payload -> nil
    end
  end

  defp normalize_transport("stdio"), do: :stdio
  defp normalize_transport("sse"), do: :sse
  defp normalize_transport("streamable_http"), do: :streamable_http
  defp normalize_transport(transport), do: transport
end
