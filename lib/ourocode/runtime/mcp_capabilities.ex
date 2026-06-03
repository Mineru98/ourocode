defmodule Ourocode.Runtime.McpCapabilities do
  @moduledoc """
  Absorbs MCP tool capability graphs into the live command registry.
  """

  alias Ourocode.MCP.Graph
  alias Ourocode.Runtime.Application

  @spec ingest(map(), [map()] | term()) :: {:ok, term()} | {:error, term()}
  def ingest(runtime, tools) when is_list(tools) do
    skills =
      tools
      |> Enum.map(&capability_skill/1)
      |> Enum.reject(&is_nil/1)

    case skills do
      [] ->
        {:ok, :no_capabilities}

      skills ->
        Application.discover_dynamic_skills(runtime, skills,
          reason: :mcp_capability_discovery,
          discovered_from: "ouroboros-mcp",
          source_id: "ouroboros"
        )
    end
  rescue
    exception -> {:error, {:capability_ingest_failed, Exception.message(exception)}}
  end

  def ingest(_runtime, _tools), do: {:ok, :no_capabilities}

  @spec maybe_ingest(map(), map()) :: :ok | {:ok, term()} | {:error, term()}
  def maybe_ingest(runtime, event) do
    case tools_from_event(event) do
      [] -> :ok
      tools -> ingest(runtime, tools)
    end
  rescue
    _exception -> :ok
  end

  @spec tools_from_event(term()) :: [map()]
  def tools_from_event(event) when is_map(event) do
    Graph.tools_from_event(event)
  end

  def tools_from_event(_event), do: []

  @spec capability_skill(map()) :: map() | nil
  def capability_skill(tool) when is_map(tool) do
    name = tool["name"] || tool[:name]

    if is_binary(name) and name != "" do
      description = tool["description"] || tool[:description] || name

      input_schema =
        tool["inputSchema"] || tool[:inputSchema] || tool["input_schema"] || tool[:input_schema] ||
          %{}

      %{
        "name" => name,
        "id" => name,
        "description" => to_string(description),
        "mcp_tool" => name,
        "input_schema" => input_schema,
        "args" => args_from_schema(input_schema),
        "source_id" => "ouroboros",
        "discovered_from" => "ouroboros-mcp"
      }
    end
  end

  def capability_skill(_tool), do: nil

  defp args_from_schema(%{} = schema) do
    required = schema |> Map.get("required", Map.get(schema, :required, [])) |> List.wrap()
    required = MapSet.new(required, &to_string/1)

    schema
    |> Map.get("properties", Map.get(schema, :properties, %{}))
    |> case do
      properties when is_map(properties) ->
        properties
        |> Enum.map(fn {name, definition} ->
          name = to_string(name)
          definition = if is_map(definition), do: definition, else: %{}

          %{
            "name" => name,
            "required" => MapSet.member?(required, name),
            "description" =>
              to_string(Map.get(definition, "description", Map.get(definition, :description, "")))
          }
        end)
        |> Enum.sort_by(& &1["name"])

      _properties ->
        []
    end
  end

  defp args_from_schema(_schema), do: []
end
