defmodule Ourocode.MCP.ChildSessionRuntimeIds do
  @moduledoc """
  Extracts runtime metadata used for child-session fallback IDs.
  """

  alias Ourocode.MCP.ChildSessionPayloads
  alias Ourocode.MCP.RuntimeEventParser

  @sources [
    :execution_id,
    :job_id,
    :lineage_id,
    :native_session_id,
    :thread_id,
    :session_id,
    :input_session_id,
    :input_call_id,
    :call_id,
    :request_id
  ]

  @spec sources() :: [atom()]
  def sources, do: @sources

  @spec preferred(map()) :: {atom(), String.t()} | nil
  def preferred(event) when is_map(event) do
    runtime_ids = fallback_runtime_ids(event)

    sources()
    |> Enum.map(fn
      :input_session_id ->
        {:input_session_id,
         nested_value(runtime_ids, :input, :sessionID) ||
           value(runtime_ids, :input_sessionID)}

      :input_call_id ->
        {:input_call_id,
         nested_value(runtime_ids, :input, :callID) ||
           value(runtime_ids, :input_callID)}

      :request_id ->
        {:request_id, value(event, :request_id)}

      source ->
        {source, value(runtime_ids, source)}
    end)
    |> Enum.find(fn {_source, value} -> present?(value) end)
  end

  @spec value(map(), atom()) :: String.t() | nil
  def value(map, key) when is_map(map) do
    map
    |> ChildSessionPayloads.any([key, Atom.to_string(key)])
    |> normalize()
  end

  def value(_map, _key), do: nil

  defp fallback_runtime_ids(event) do
    case ChildSessionPayloads.field(event, :fallback_runtime_metadata) do
      metadata when is_map(metadata) and map_size(metadata) > 0 -> metadata
      _metadata -> runtime_ids(event)
    end
  end

  defp runtime_ids(event) do
    event_external_ids =
      case ChildSessionPayloads.field(event, :external_ids) do
        external_ids when is_map(external_ids) -> valid_runtime_ids(external_ids)
        _external_ids -> %{}
      end

    event
    |> RuntimeEventParser.extract_external_ids()
    |> Map.merge(event_external_ids)
  end

  defp valid_runtime_ids(runtime_ids) do
    Enum.reduce(runtime_ids, %{}, fn {key, value}, acc ->
      cond do
        is_map(value) ->
          Map.put(acc, key, value)

        true ->
          case normalize(value) do
            nil -> acc
            normalized -> Map.put(acc, key, normalized)
          end
      end
    end)
  end

  defp nested_value(map, parent_key, child_key) when is_map(map) do
    map
    |> ChildSessionPayloads.any([parent_key, Atom.to_string(parent_key)])
    |> case do
      nested when is_map(nested) -> value(nested, child_key)
      _nested -> nil
    end
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize(_value), do: nil

  defp present?(value), do: value not in [nil, ""]
end
