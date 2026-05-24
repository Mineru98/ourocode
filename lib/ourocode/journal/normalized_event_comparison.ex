defmodule Ourocode.Journal.NormalizedEventComparison do
  @moduledoc """
  Duplicate-safe, order-aware comparison for normalized journal events.
  """

  alias Ourocode.Journal.SourceTransportNormalizer
  alias Ourocode.MCP.LifecycleEvent

  @normalized_event_diagnostic_keys MapSet.new(["raw_event"])

  @spec compare([map()], [map() | LifecycleEvent.t()]) :: {:ok, map()} | {:error, map()}
  def compare(journaled_events, source_events)
      when is_list(journaled_events) and is_list(source_events) do
    journaled_index = normalized_event_index(journaled_events)
    source_index = normalized_event_index(source_events)

    journaled_keys = journaled_index |> Map.keys() |> MapSet.new()
    source_keys = source_index |> Map.keys() |> MapSet.new()

    missing =
      source_keys
      |> MapSet.difference(journaled_keys)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(&comparison_event_summary(source_index, &1))

    extra =
      journaled_keys
      |> MapSet.difference(source_keys)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(&comparison_event_summary(journaled_index, &1))

    mismatched =
      source_keys
      |> MapSet.intersection(journaled_keys)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.reduce([], fn key, acc ->
        source = Map.fetch!(source_index, key)
        journaled = Map.fetch!(journaled_index, key)

        if source.canonical == journaled.canonical do
          acc
        else
          [
            %{
              identity: normalized_event_identity_report(key),
              source_index: source.index,
              journaled_index: journaled.index,
              differing_fields:
                differing_normalized_fields(source.canonical, journaled.canonical),
              source_event: source.canonical,
              journaled_event: journaled.canonical
            }
            | acc
          ]
        end
      end)
      |> Enum.reverse()

    report = %{
      type: :normalized_event_no_loss_comparison,
      status: if(missing == [] and extra == [] and mismatched == [], do: :ok, else: :failed),
      source_event_count: length(source_events),
      journaled_event_count: length(journaled_events),
      missing_count: length(missing),
      extra_count: length(extra),
      mismatched_count: length(mismatched),
      missing_normalized_events: missing,
      extra_normalized_events: extra,
      mismatched_normalized_events: mismatched
    }

    if report.status == :ok do
      {:ok, report}
    else
      {:error, Map.put(report, :reason, :normalized_event_no_loss_comparison_failed)}
    end
  end

  @spec compare_source_transport_events([map()], [map() | LifecycleEvent.t()], keyword() | map()) ::
          {:ok, map()} | {:error, map()}
  def compare_source_transport_events(journaled_events, source_transport_events, options \\ [])
      when is_list(journaled_events) and is_list(source_transport_events) do
    with {:ok, normalized_source_events, normalization_report} <-
           SourceTransportNormalizer.normalize(source_transport_events, options) do
      case compare(journaled_events, normalized_source_events) do
        {:ok, report} ->
          {:ok, Map.put(report, :source_normalization, normalization_report)}

        {:error, report} ->
          {:error, Map.put(report, :source_normalization, normalization_report)}
      end
    end
  end

  defp normalized_event_index(events) do
    {index, _counts} =
      events
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}}, fn {event, position}, {index, counts} ->
        canonical = canonical_normalized_event(event)
        base_identity = normalized_event_base_identity(canonical)
        occurrence = Map.get(counts, base_identity, 0) + 1
        key = {base_identity, occurrence}

        entry = %{
          identity: base_identity,
          occurrence: occurrence,
          index: position,
          canonical: canonical
        }

        {Map.put(index, key, entry), Map.put(counts, base_identity, occurrence)}
      end)

    index
  end

  defp normalized_event_base_identity(%{"event_seq" => event_seq}) when is_integer(event_seq) do
    {:event_seq, event_seq}
  end

  defp normalized_event_base_identity(%{"event_seq" => event_seq}) when is_binary(event_seq) do
    case Integer.parse(String.trim(event_seq)) do
      {integer, ""} -> {:event_seq, integer}
      _parse_error -> {:fingerprint, canonical_event_fingerprint(%{"event_seq" => event_seq})}
    end
  end

  defp normalized_event_base_identity(canonical) do
    {:fingerprint, canonical_event_fingerprint(canonical)}
  end

  defp canonical_event_fingerprint(canonical) do
    canonical
    |> Ourocode.Json.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp comparison_event_summary(index, key) do
    entry = Map.fetch!(index, key)

    %{
      identity: normalized_event_identity_report(key),
      event_index: entry.index,
      event: entry.canonical
    }
  end

  defp normalized_event_identity_report({{kind, value}, occurrence}) do
    %{
      kind: kind,
      value: value,
      occurrence: occurrence
    }
  end

  defp differing_normalized_fields(left, right) when is_map(left) and is_map(right) do
    left_keys = left |> Map.keys() |> MapSet.new()
    right_keys = right |> Map.keys() |> MapSet.new()

    left_keys
    |> MapSet.union(right_keys)
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.reject(fn key -> Map.get(left, key) == Map.get(right, key) end)
  end

  defp differing_normalized_fields(_left, _right), do: [:root]

  defp canonical_normalized_event(%LifecycleEvent{} = event) do
    event
    |> Map.from_struct()
    |> canonical_normalized_event()
  end

  defp canonical_normalized_event(%{} = event) do
    event
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      normalized_key = to_string(key)

      cond do
        MapSet.member?(@normalized_event_diagnostic_keys, normalized_key) ->
          acc

        true ->
          case canonical_normalized_value(value) do
            nil -> acc
            canonical_value -> Map.put(acc, normalized_key, canonical_value)
          end
      end
    end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Map.new()
  end

  defp canonical_normalized_value(%LifecycleEvent{} = event),
    do: canonical_normalized_event(event)

  defp canonical_normalized_value(%{} = map), do: canonical_normalized_event(map)

  defp canonical_normalized_value(list) when is_list(list) do
    Enum.map(list, &canonical_normalized_value/1)
  end

  defp canonical_normalized_value(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> canonical_normalized_value()
  end

  defp canonical_normalized_value(nil), do: nil
  defp canonical_normalized_value(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical_normalized_value(value), do: value
end
