defmodule Ourocode.Journal.SourceTransportNormalizer.Context do
  @moduledoc """
  Context normalization for source transport event replay.
  """

  @default %{
    event_seq: 1,
    parent_call_id: "source-transport-validation",
    runtime_source: "source-transport-validation",
    external_ids: %{}
  }

  @spec from_options(keyword() | map() | term()) :: map()
  def from_options(options) do
    options
    |> options_map()
    |> Map.get(:context, %{})
    |> normalize()
  end

  @spec for_event(term(), map(), integer()) :: map()
  def for_event(source_event, default_context, next_seq) do
    source_context = source_context(source_event)

    default_context
    |> Map.put(:event_seq, next_seq)
    |> Map.merge(source_context)
  end

  @spec normalize(term()) :: map()
  def normalize(context) when is_map(context) do
    @default
    |> Map.merge(normalize_partial(context))
    |> ensure_external_ids()
  end

  def normalize(_context), do: @default

  @spec normalize_partial(term()) :: map()
  def normalize_partial(context) when is_map(context) do
    context
    |> atomize_known_context_keys()
    |> ensure_external_ids()
  end

  def normalize_partial(_context), do: %{}

  defp source_context(%{} = event) do
    event
    |> Map.get(:context, Map.get(event, "context", %{}))
    |> normalize_partial()
  end

  defp source_context(_event), do: %{}

  defp ensure_external_ids(%{external_ids: external_ids} = context) when is_map(external_ids),
    do: context

  defp ensure_external_ids(%{external_ids: _external_ids} = context),
    do: Map.put(context, :external_ids, %{})

  defp ensure_external_ids(context), do: context

  defp atomize_known_context_keys(context) do
    Enum.reduce(context, %{}, fn {key, value}, acc ->
      case normalize_context_key(key) do
        nil -> acc
        normalized_key -> Map.put(acc, normalized_key, value)
      end
    end)
  end

  defp normalize_context_key(key)
       when key in [
              :event_seq,
              :parent_call_id,
              :runtime_source,
              :external_ids,
              :occurred_at_ms,
              :status,
              :headers,
              :request_id,
              :method,
              :params
            ],
       do: key

  defp normalize_context_key(key) when is_binary(key) do
    Map.get(
      %{
        "event_seq" => :event_seq,
        "parent_call_id" => :parent_call_id,
        "runtime_source" => :runtime_source,
        "external_ids" => :external_ids,
        "occurred_at_ms" => :occurred_at_ms,
        "status" => :status,
        "headers" => :headers,
        "request_id" => :request_id,
        "method" => :method,
        "params" => :params
      },
      key
    )
  end

  defp normalize_context_key(_key), do: nil

  defp options_map(options) when is_list(options), do: Map.new(options)
  defp options_map(options) when is_map(options), do: options
  defp options_map(_options), do: %{}
end
