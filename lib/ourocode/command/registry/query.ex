defmodule Ourocode.Command.Registry.Query do
  @moduledoc false

  @spec run(map(), [term()]) :: [map()]
  def run(registry, filters) when is_map(registry) and is_list(filters) do
    filters = normalize_filters(filters)

    registry
    |> entries()
    |> Enum.filter(&matches?(&1, filters))
    |> maybe_limit(filters)
  end

  @spec normalize_filters([term()]) :: keyword()
  def normalize_filters(filters) when is_list(filters) do
    filters
    |> Enum.flat_map(fn
      {:source, source} ->
        [{:sources, MapSet.new([source])}]

      {:sources, sources} ->
        [{:sources, sources |> List.wrap() |> MapSet.new()}]

      {:category, category} ->
        [{:categories, MapSet.new([category])}]

      {:categories, categories} ->
        [{:categories, categories |> List.wrap() |> MapSet.new()}]

      {:transport, transport} ->
        [{:transports, MapSet.new([normalize_transport(transport)])}]

      {:transports, transports} ->
        [
          {:transports,
           transports |> List.wrap() |> Enum.map(&normalize_transport/1) |> MapSet.new()}
        ]

      {:plugin_id, plugin_id} ->
        [{:plugin_ids, MapSet.new([to_string(plugin_id)])}]

      {:plugin_ids, plugin_ids} ->
        [{:plugin_ids, plugin_ids |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()}]

      {:source_id, source_id} ->
        [{:source_ids, MapSet.new([to_string(source_id)])}]

      {:source_ids, source_ids} ->
        [{:source_ids, source_ids |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()}]

      {:type, type} ->
        [{:types, MapSet.new([type])}]

      {:types, types} ->
        [{:types, types |> List.wrap() |> MapSet.new()}]

      {:prefix, prefix} ->
        [{:prefix, normalize_slash(to_string(prefix))}]

      {:query, query} ->
        [{:query, normalize_search_text(query)}]

      {:text, query} ->
        [{:query, normalize_search_text(query)}]

      {:availability, availability} ->
        [{:availability, availability}]

      {:runnable?, runnable?} when is_boolean(runnable?) ->
        [{:runnable?, runnable?}]

      {:limit, limit} when is_integer(limit) and limit > 0 ->
        [{:limit, limit}]

      _unknown ->
        []
    end)
  end

  @spec matches?(map(), keyword()) :: boolean()
  def matches?(entry, filters) when is_map(entry) and is_list(filters) do
    Enum.all?(filters, fn
      {:sources, sources} -> MapSet.member?(sources, entry.source)
      {:categories, categories} -> MapSet.member?(categories, entry.category)
      {:availability, availability} -> entry.availability == availability
      {:runnable?, runnable?} -> entry.runnable? == runnable?
      {:transports, transports} -> MapSet.member?(transports, entry_transport(entry))
      {:plugin_ids, plugin_ids} -> MapSet.member?(plugin_ids, entry_plugin_id(entry))
      {:source_ids, source_ids} -> MapSet.member?(source_ids, to_string(entry.source_id))
      {:types, types} -> MapSet.member?(types, entry.type)
      {:prefix, prefix} -> entry_prefix_match?(entry, prefix)
      {:query, ""} -> true
      {:query, query} -> entry_search_match?(entry, query)
      {:limit, _limit} -> true
    end)
  end

  defp entries(%{ordered: ordered}) when is_list(ordered), do: ordered
  defp entries(_registry), do: []

  defp maybe_limit(entries, filters) do
    case Keyword.get(filters, :limit) do
      limit when is_integer(limit) and limit > 0 -> Enum.take(entries, limit)
      _none -> entries
    end
  end

  defp entry_transport(entry) do
    Map.get(entry.metadata, :transport) ||
      Map.get(entry.run_spec, :transport) ||
      Map.get(entry.source_attribution, :transport)
  end

  defp entry_plugin_id(entry) do
    plugin_id =
      Map.get(entry.metadata, :plugin_id) ||
        Map.get(entry.run_spec, :plugin_id) ||
        Map.get(entry.source_attribution, :plugin_id)

    if is_nil(plugin_id), do: nil, else: to_string(plugin_id)
  end

  defp entry_prefix_match?(entry, prefix) do
    Enum.any?([entry.slash | entry.aliases], &String.starts_with?(&1, prefix))
  end

  defp entry_search_match?(entry, query) do
    entry
    |> entry_search_values()
    |> Enum.any?(fn value ->
      value
      |> normalize_search_text()
      |> String.contains?(query)
    end)
  end

  defp entry_search_values(entry) do
    arg_values =
      entry.args
      |> Enum.flat_map(fn arg ->
        [arg.name, Map.get(arg, :description, "")]
      end)

    metadata_values = [
      Map.get(entry.metadata, :plugin_id),
      Map.get(entry.metadata, :plugin_source),
      Map.get(entry.metadata, :tool_name),
      Map.get(entry.metadata, :server_id),
      Map.get(entry.metadata, :transport),
      Map.get(entry.metadata, :discovered_from),
      Map.get(entry.metadata, :command_namespace)
    ]

    run_spec_values = [
      Map.get(entry.run_spec, :kind),
      Map.get(entry.run_spec, :action),
      Map.get(entry.run_spec, :mcp_tool),
      Map.get(entry.run_spec, :tool_name),
      Map.get(entry.run_spec, :plugin_id),
      Map.get(entry.run_spec, :server_id),
      Map.get(entry.run_spec, :transport)
    ]

    [
      entry.id,
      entry.name,
      entry.slash,
      entry.source,
      entry.source_id,
      entry.category,
      entry.summary
      | entry.aliases ++ arg_values ++ metadata_values ++ run_spec_values
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp normalize_search_text(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_slash(command) when is_binary(command) do
    command = String.trim(command)

    if String.starts_with?(command, "/") do
      command
    else
      "/#{command}"
    end
  end

  defp normalize_transport("streamable_http"), do: :streamable_http
  defp normalize_transport("streamable-http"), do: :streamable_http
  defp normalize_transport("stdio"), do: :stdio
  defp normalize_transport("sse"), do: :sse
  defp normalize_transport(transport) when is_atom(transport), do: transport
  defp normalize_transport(transport) when is_binary(transport), do: transport
  defp normalize_transport(_transport), do: :unknown
end
