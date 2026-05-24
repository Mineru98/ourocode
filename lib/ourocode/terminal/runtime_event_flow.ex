defmodule Ourocode.Terminal.RuntimeEventFlow do
  @moduledoc """
  Normalization and recoverable-error helpers for terminal runtime events.
  """

  @spec poll(function() | term(), map()) :: :none | {:ok, map()} | {:error, term()}
  def poll(poller, state) do
    poll_result =
      cond do
        is_function(poller, 1) -> poller.(state)
        is_function(poller, 0) -> poller.()
        true -> :none
      end

    normalize_poll(poll_result)
  rescue
    exception ->
      {:error,
       {:runtime_event_poller_exception, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:runtime_event_poller_caught, kind, reason}}
  end

  @spec normalize_poll(term()) :: :none | {:ok, map()} | {:error, term()}
  def normalize_poll(nil), do: :none
  def normalize_poll(:none), do: :none
  def normalize_poll(:empty), do: :none
  def normalize_poll({:ok, nil}), do: :none
  def normalize_poll({:ok, event}) when is_map(event), do: {:ok, event}
  def normalize_poll(event) when is_map(event), do: {:ok, event}
  def normalize_poll({:error, reason}), do: {:error, reason}
  def normalize_poll(other), do: {:error, {:invalid_runtime_event_poll, other}}

  @spec normalize_event(map()) :: map()
  def normalize_event(event) when is_map(event) do
    type =
      event
      |> event_value(:type, event_value(event, :event_type, :runtime_event))
      |> normalize_event_type()

    event
    |> Map.put(:type, type)
    |> Map.put_new(:source, :runtime)
    |> Map.put_new(:occurred_at_ms, System.system_time(:millisecond))
    |> Map.put_new(:event_type, type)
  end

  @spec recoverable_event?(map()) :: boolean()
  def recoverable_event?(%{recoverable?: true}), do: true
  def recoverable_event?(%{severity: :recoverable}), do: true

  def recoverable_event?(%{type: type})
      when type in [:recoverable_error, :recoverable_stream_gap],
      do: true

  def recoverable_event?(_event), do: false

  @spec recoverable_error_event(term(), term(), term()) :: map()
  def recoverable_error_event(type, reason, source) do
    %{
      type: :terminal_recoverable_error,
      event_type: :terminal_recoverable_error,
      source: source,
      recoverable?: true,
      error_type: type,
      reason: reason,
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        error_type: type,
        reason: reason
      }
    }
  end

  defp normalize_event_type(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_event_type(value), do: value

  defp event_value(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end
end
