defmodule Ourocode.Journal.Codec do
  @moduledoc false

  alias Ourocode.Journal.Codec.Registry
  alias Ourocode.MCP.LifecycleEvent

  @raw_event_encoded_map_marker "__ourocode_raw_event_encoded_map__"
  @raw_event_encoded_map_entries "entries"
  @raw_event_encoded_value_marker "__ourocode_raw_event_encoded_value__"

  @spec encode(map() | LifecycleEvent.t()) :: map()
  def encode(%LifecycleEvent{} = event), do: event |> Map.from_struct() |> encode()

  def encode(%{} = map) do
    Map.new(map, fn
      {key, value} when key in [:raw_event, "raw_event"] ->
        {to_string(key), encode_raw_event(value)}

      {key, value} ->
        {to_string(key), encode(value)}
    end)
  end

  def encode(list) when is_list(list), do: Enum.map(list, &encode/1)
  def encode(nil), do: nil
  def encode(value) when is_boolean(value), do: value
  def encode(value) when is_atom(value), do: Atom.to_string(value)
  def encode(value) when is_tuple(value), do: value |> Tuple.to_list() |> encode()
  def encode(value), do: value

  @spec decode(map()) :: map()
  def decode(%{} = map) do
    Map.new(map, fn {key, value} ->
      restored_key = restore_top_level_key(key)
      {restored_key, restore_value(restored_key, value)}
    end)
  end

  defp encode_raw_event(value) when is_atom(value) do
    %{
      @raw_event_encoded_value_marker => true,
      "type" => "atom",
      "value" => Atom.to_string(value)
    }
  end

  defp encode_raw_event(value) when is_tuple(value) do
    %{
      @raw_event_encoded_value_marker => true,
      "type" => "tuple",
      "value" => value |> Tuple.to_list() |> encode_raw_event()
    }
  end

  defp encode_raw_event(%{} = map), do: encode_raw_event_map(map)
  defp encode_raw_event(list) when is_list(list), do: Enum.map(list, &encode_raw_event/1)
  defp encode_raw_event(value), do: encode(value)

  defp encode_raw_event_map(map) do
    if Enum.all?(map, fn {key, _value} -> is_binary(key) end) do
      Map.new(map, fn {key, value} -> {key, encode_raw_event(value)} end)
    else
      %{
        @raw_event_encoded_map_marker => true,
        @raw_event_encoded_map_entries =>
          Enum.map(map, fn {key, value} ->
            %{
              "key" => encode_raw_event_key(key),
              "value" => encode_raw_event(value)
            }
          end)
      }
    end
  end

  defp encode_raw_event_key(key) when is_binary(key), do: %{"type" => "string", "value" => key}

  defp encode_raw_event_key(key) when is_atom(key),
    do: %{"type" => "atom", "value" => Atom.to_string(key)}

  defp encode_raw_event_key(key) when is_tuple(key),
    do: %{"type" => "tuple", "value" => key |> Tuple.to_list() |> encode_raw_event()}

  defp encode_raw_event_key(key), do: %{"type" => "term", "value" => inspect(key)}

  defp restore_top_level_key(key), do: Registry.top_level_key(key)

  defp restore_value(key, value)
       when key in [
              :type,
              :event_type,
              :transport,
              :question_kind,
              :source,
              :change,
              :reason,
              :relevance,
              :reload_boundary,
              :input_kind,
              :steering_target
            ],
       do: restore_known_atom(value)

  defp restore_value(:raw_event, value), do: restore_raw_event(value)
  defp restore_value(:external_ids, value), do: restore_external_ids(value)
  defp restore_value(_key, value), do: restore_nested(value)

  defp restore_external_ids(%{} = map) do
    restored = restore_nested(map)

    restored
    |> maybe_put_alias(:childID, Map.get(restored, "childID"))
    |> maybe_put_alias(:child_id, Map.get(restored, "child_id"))
    |> maybe_put_alias(:session_id, Map.get(restored, "session_id"))
    |> maybe_put_alias(:thread_id, Map.get(restored, "thread_id"))
    |> maybe_put_alias(:job_id, Map.get(restored, "job_id"))
    |> maybe_put_alias(:execution_id, Map.get(restored, "execution_id"))
    |> maybe_put_alias(:lineage_id, Map.get(restored, "lineage_id"))
  end

  defp restore_external_ids(value), do: restore_nested(value)

  defp maybe_put_alias(map, _key, nil), do: map
  defp maybe_put_alias(map, key, value), do: Map.put_new(map, key, value)

  defp restore_nested(%{} = map) do
    Map.new(map, fn {key, value} -> {key, restore_nested(value)} end)
  end

  defp restore_nested(list) when is_list(list), do: Enum.map(list, &restore_nested/1)
  defp restore_nested(value), do: value

  defp restore_raw_event(%{
         @raw_event_encoded_map_marker => true,
         @raw_event_encoded_map_entries => entries
       })
       when is_list(entries) do
    Map.new(entries, fn
      %{"key" => key, "value" => value} ->
        {restore_raw_event_key(key), restore_raw_event(value)}

      entry ->
        {entry, nil}
    end)
  end

  defp restore_raw_event(%{
         @raw_event_encoded_value_marker => true,
         "type" => "atom",
         "value" => value
       })
       when is_binary(value) do
    restore_existing_atom(value)
  end

  defp restore_raw_event(%{
         @raw_event_encoded_value_marker => true,
         "type" => "tuple",
         "value" => value
       })
       when is_list(value) do
    value |> Enum.map(&restore_raw_event/1) |> List.to_tuple()
  end

  defp restore_raw_event(%{} = map) do
    Map.new(map, fn {key, value} -> {key, restore_raw_event(value)} end)
  end

  defp restore_raw_event(list) when is_list(list), do: Enum.map(list, &restore_raw_event/1)
  defp restore_raw_event(value), do: restore_nested(value)

  defp restore_raw_event_key(%{"type" => "string", "value" => value}) when is_binary(value),
    do: value

  defp restore_raw_event_key(%{"type" => "atom", "value" => value}) when is_binary(value),
    do: restore_existing_atom(value)

  defp restore_raw_event_key(%{"type" => "tuple", "value" => value}) when is_list(value),
    do: value |> Enum.map(&restore_raw_event/1) |> List.to_tuple()

  defp restore_raw_event_key(%{"value" => value}), do: value
  defp restore_raw_event_key(value), do: value

  defp restore_known_atom(value) when is_binary(value), do: Registry.atom_value(value)
  defp restore_known_atom(value), do: value

  defp restore_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end
end
