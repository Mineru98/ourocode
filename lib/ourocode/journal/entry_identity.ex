defmodule Ourocode.Journal.EntryIdentity do
  @moduledoc """
  Extracts stable identities from decoded journal entries.
  """

  @spec child_event_identity(map()) :: {:ok, String.t()} | {:error, term()}
  def child_event_identity(%{} = entry) do
    with child_id when is_binary(child_id) and child_id != "" <- child_id(entry),
         event_seq when is_integer(event_seq) <- map_value(entry, :event_seq) do
      {:ok,
       [
         "child-event",
         identity_component(:parent, map_value(entry, :parent_call_id)),
         identity_component(:child, child_id),
         identity_component(:runtime, map_value(entry, :runtime_source)),
         identity_component(:transport, map_value(entry, :transport)),
         identity_component(:event_seq, event_seq),
         identity_component(:runtime_seq, child_runtime_seq(entry))
       ]
       |> Enum.join(":")}
    else
      nil -> {:error, :missing_child_event_identity}
      _value -> {:error, :missing_child_event_identity}
    end
  end

  def child_event_identity(_entry), do: {:error, :missing_child_event_identity}

  @spec child_event_identity_value(map()) :: String.t() | nil
  def child_event_identity_value(entry) do
    case child_event_identity(entry) do
      {:ok, child_event_id} -> child_event_id
      {:error, _reason} -> nil
    end
  end

  @spec child_id(map()) :: String.t() | nil
  def child_id(entry) when is_map(entry) do
    map_value(entry, :child_id) ||
      entry_external_id(entry, "childID") ||
      entry_external_id(entry, "child_id") ||
      payload_child_id(entry) ||
      raw_event_child_id(entry)
  end

  def child_id(_entry), do: nil

  @spec map_value(map(), atom()) :: term()
  def map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  def map_value(_map, _key), do: nil

  defp entry_external_id(entry, key) do
    case map_value(entry, :external_ids) do
      external_ids when is_map(external_ids) ->
        Map.get(external_ids, key) || Map.get(external_ids, external_id_atom_key(key))

      _external_ids ->
        nil
    end
  end

  defp external_id_atom_key("childID"), do: :childID
  defp external_id_atom_key("child_id"), do: :child_id

  defp payload_child_id(entry) do
    case map_value(entry, :payload) do
      payload when is_map(payload) ->
        Map.get(payload, "childID") || Map.get(payload, :childID) ||
          Map.get(payload, "child_id") || Map.get(payload, :child_id)

      _payload ->
        nil
    end
  end

  defp raw_event_child_id(entry) do
    params =
      entry
      |> map_value(:raw_event)
      |> raw_event_data()
      |> raw_event_params()

    if is_map(params) do
      Map.get(params, "childID") || Map.get(params, :childID) ||
        Map.get(params, "child_id") || Map.get(params, :child_id)
    end
  end

  defp raw_event_data(raw_event) when is_map(raw_event) do
    Map.get(raw_event, "data") || Map.get(raw_event, :data) || raw_event
  end

  defp raw_event_data(_raw_event), do: nil

  defp raw_event_params(data) when is_map(data) do
    Map.get(data, "params") || Map.get(data, :params) || data
  end

  defp raw_event_params(_data), do: nil

  defp child_runtime_seq(entry) when is_map(entry) do
    entry
    |> child_runtime_seq_candidates()
    |> Enum.find_value(&integer_value/1)
  end

  defp child_runtime_seq(_entry), do: nil

  defp child_runtime_seq_candidates(entry) do
    [
      map_value(entry, :runtime_seq),
      map_value(entry, :rendered_event_seq),
      map_value(map_value(entry, :payload), :runtime_seq),
      map_value(map_value(entry, :payload), :seq),
      map_value(map_value(entry, :payload), :event_seq),
      map_value(map_value(entry, :stream_cursor), :runtime_seq),
      map_value(map_value(entry, :stream_cursor), :seq)
    ]
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _parse_error -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp identity_component(name, value) do
    value = identity_component_value(value)
    Atom.to_string(name) <> "=" <> Integer.to_string(byte_size(value)) <> ":" <> value
  end

  defp identity_component_value(nil), do: "none"
  defp identity_component_value(value) when is_atom(value), do: Atom.to_string(value)
  defp identity_component_value(value), do: to_string(value)
end
