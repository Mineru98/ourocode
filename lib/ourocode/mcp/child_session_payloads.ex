defmodule Ourocode.MCP.ChildSessionPayloads do
  @moduledoc """
  Traverses normalized MCP event payload locations for child-session parsing.
  """

  @spec candidates(map()) :: [{atom(), map()}]
  def candidates(event) when is_map(event) do
    [
      {:event, event},
      {:data, field(event, :data)},
      {:data_params, nested(event, [:data, "params"])},
      {:data_params, nested(event, [:data, :params])},
      {:data_result, nested(event, [:data, "result"])},
      {:data_result, nested(event, [:data, :result])},
      {:external_ids, field(event, :external_ids)},
      {:params, field(event, :params)},
      {:notification, field(event, :notification)},
      {:notification_params, nested(event, [:notification, "params"])},
      {:notification_params, nested(event, [:notification, :params])},
      {:notification_result, nested(event, [:notification, "result"])},
      {:notification_result, nested(event, [:notification, :result])},
      {:result, field(event, :result)},
      {:result_params, nested(event, [:result, "params"])},
      {:result_params, nested(event, [:result, :params])},
      {:raw_event, field(event, :raw_event)},
      {:raw_event_data, nested(event, [:raw_event, "data"])},
      {:raw_event_data, nested(event, [:raw_event, :data])},
      {:raw_event_data_params, nested(event, [:raw_event, "data", "params"])},
      {:raw_event_data_params, nested(event, [:raw_event, :data, :params])},
      {:raw_event_data_result, nested(event, [:raw_event, "data", "result"])},
      {:raw_event_data_result, nested(event, [:raw_event, :data, :result])},
      {:raw_event_params, nested(event, [:raw_event, "params"])},
      {:raw_event_params, nested(event, [:raw_event, :params])},
      {:raw_event_result, nested(event, [:raw_event, "result"])},
      {:raw_event_result, nested(event, [:raw_event, :result])}
    ]
    |> Enum.filter(fn {_path, payload} -> is_map(payload) end)
  end

  @spec field(map(), atom()) :: term()
  def field(map, key) when is_map(map) and is_atom(key) do
    any(map, [key, Atom.to_string(key)])
  end

  @spec nested(map(), [atom() | String.t()]) :: term()
  def nested(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      cond do
        is_map(acc) and Map.has_key?(acc, key) ->
          {:cont, Map.get(acc, key)}

        is_map(acc) and is_atom(key) and Map.has_key?(acc, Atom.to_string(key)) ->
          {:cont, Map.get(acc, Atom.to_string(key))}

        is_map(acc) and is_binary(key) ->
          atom_key = safe_existing_atom(key)

          if atom_key && Map.has_key?(acc, atom_key) do
            {:cont, Map.get(acc, atom_key)}
          else
            {:halt, nil}
          end

        true ->
          {:halt, nil}
      end
    end)
  end

  @spec any(map(), [term()]) :: term()
  def any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
