defmodule Ourocode.MCP.Graph do
  @moduledoc """
  Normalizes MCP capability discovery into a small server/tool graph.

  The graph is deliberately data-only so the command registry, dashboard, and
  future MCP graph view can share one interpretation of `tools/list` payloads.
  """

  @type server :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          optional(:transport) => atom() | String.t(),
          optional(:runtime_source) => String.t(),
          optional(:source_id) => String.t()
        }

  @type tool :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:server_id) => String.t(),
          optional(:description) => String.t(),
          optional(:input_schema) => map(),
          optional(:raw) => map()
        }

  @type edge :: %{
          required(:from) => String.t(),
          required(:to) => String.t(),
          required(:kind) => :server_tool
        }

  @type t :: %{
          required(:servers) => [server()],
          required(:tools) => [tool()],
          required(:edges) => [edge()]
        }

  @spec from_event(map() | term(), keyword()) :: t()
  def from_event(event, opts \\ []) do
    server = server_from_event(event, opts)

    tools =
      event
      |> tools_from_event()
      |> Enum.map(&normalize_tool(&1, server))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    %{
      servers: if(tools == [], do: [], else: [server]),
      tools: tools,
      edges: Enum.map(tools, &%{from: server.id, to: &1.id, kind: :server_tool})
    }
  end

  @spec tools_from_event(term()) :: [map()]
  def tools_from_event(event) when is_map(event) do
    event
    |> Map.get(:payload, event)
    |> dig_tools()
  end

  def tools_from_event(_event), do: []

  @doc """
  Renders a compact text view of discovered MCP servers, tools, and schemas.
  """
  @spec render_text(t()) :: String.t()
  def render_text(%{servers: servers, tools: tools, edges: _edges}) do
    tool_count = length(tools)

    lines =
      ["MCPGraph: #{length(servers)} servers, #{tool_count} tools"] ++
        Enum.flat_map(servers, fn server ->
          server_tools = Enum.filter(tools, &(&1.server_id == server.id))

          [
            "  server #{server.name} id=#{server.id}" <>
              optional_segment(" transport=", Map.get(server, :transport))
          ] ++ Enum.flat_map(server_tools, &tool_lines/1)
        end)

    Enum.join(lines, "\n")
  end

  def render_text(_graph), do: "MCPGraph: 0 servers, 0 tools"

  @spec normalize_tool(map(), server()) :: tool() | nil
  def normalize_tool(tool, %{id: server_id}) when is_map(tool) and is_binary(server_id) do
    with name when is_binary(name) and name != "" <- string_value(tool, ["name", :name]) do
      id = server_id <> "/tool/" <> name

      %{
        id: id,
        name: name,
        server_id: server_id,
        description: string_value(tool, ["description", :description]) || name,
        input_schema:
          map_value(tool, ["inputSchema", :inputSchema, "input_schema", :input_schema]),
        raw: tool
      }
      |> drop_nil_values()
    else
      _value -> nil
    end
  end

  def normalize_tool(_tool, _server), do: nil

  @spec server_from_event(term(), keyword()) :: server()
  def server_from_event(event, opts \\ []) do
    source_id =
      opts[:source_id] ||
        source_value(event, [:source_id, "source_id"]) ||
        source_value(event, [:runtime_source, "runtime_source"]) ||
        "ouroboros"

    name =
      opts[:name] ||
        source_value(event, [:server_name, "server_name"]) ||
        source_value(event, [:runtime_source, "runtime_source"]) ||
        source_id

    %{
      id: "mcp-server:" <> source_id,
      name: name,
      source_id: source_id,
      runtime_source: source_value(event, [:runtime_source, "runtime_source"]),
      transport: source_value(event, [:transport, "transport"])
    }
    |> drop_nil_values()
  end

  defp dig_tools(%{} = map) do
    cond do
      is_list(map["tools"]) -> map["tools"]
      is_list(map[:tools]) -> map[:tools]
      is_map(map["result"]) -> dig_tools(map["result"])
      is_map(map[:result]) -> dig_tools(map[:result])
      is_map(map["payload"]) -> dig_tools(map["payload"])
      is_map(map[:payload]) -> dig_tools(map[:payload])
      true -> []
    end
  end

  defp dig_tools(_other), do: []

  defp source_value(event, keys) when is_map(event), do: string_value(event, keys)
  defp source_value(_event, _keys), do: nil

  defp string_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value when is_atom(value) -> Atom.to_string(value)
        value when is_binary(value) -> normalize_string(value)
        _value -> nil
      end
    end)
  end

  defp map_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_map(value) -> value
        _value -> nil
      end
    end)
  end

  defp normalize_string(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp tool_lines(tool) do
    [
      "    tool #{tool.name} id=#{tool.id}",
      "      description #{Map.get(tool, :description, tool.name)}"
    ] ++ schema_lines(Map.get(tool, :input_schema, %{}))
  end

  defp schema_lines(schema) when is_map(schema) and map_size(schema) > 0 do
    required = schema |> Map.get("required", Map.get(schema, :required, [])) |> List.wrap()
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))

    [
      "      schema type=#{Map.get(schema, "type", Map.get(schema, :type, "object"))} required=#{Enum.join(Enum.map(required, &to_string/1), ",")}"
    ] ++ property_lines(properties, required)
  end

  defp schema_lines(_schema), do: ["      schema none"]

  defp property_lines(properties, required) when is_map(properties) do
    required = MapSet.new(required, &to_string/1)

    properties
    |> Enum.sort_by(fn {name, _definition} -> to_string(name) end)
    |> Enum.map(fn {name, definition} ->
      name = to_string(name)
      definition = if is_map(definition), do: definition, else: %{}
      type = Map.get(definition, "type", Map.get(definition, :type, "any"))
      description = Map.get(definition, "description", Map.get(definition, :description, ""))
      required_mark = if MapSet.member?(required, name), do: " required", else: ""

      "      arg #{name}: #{type}#{required_mark}" <> optional_segment(" - ", description)
    end)
  end

  defp property_lines(_properties, _required), do: []

  defp optional_segment(_prefix, nil), do: ""
  defp optional_segment(_prefix, ""), do: ""
  defp optional_segment(prefix, value), do: prefix <> to_string(value)
end
