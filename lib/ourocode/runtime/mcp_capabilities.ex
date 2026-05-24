defmodule Ourocode.Runtime.McpCapabilities do
  @moduledoc """
  Absorbs MCP tool capability graphs into the live command registry.
  """

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
    event
    |> Map.get(:payload, event)
    |> dig_tools()
  end

  def tools_from_event(_event), do: []

  @spec capability_skill(map()) :: map() | nil
  def capability_skill(tool) when is_map(tool) do
    name = tool["name"] || tool[:name]

    if is_binary(name) and name != "" do
      description = tool["description"] || tool[:description] || name

      %{
        "name" => name,
        "id" => name,
        "description" => to_string(description),
        "mcp_tool" => name,
        "source_id" => "ouroboros",
        "discovered_from" => "ouroboros-mcp"
      }
    end
  end

  def capability_skill(_tool), do: nil

  defp dig_tools(%{} = map) do
    cond do
      is_list(map["tools"]) -> map["tools"]
      is_list(map[:tools]) -> map[:tools]
      is_map(map["result"]) -> dig_tools(map["result"])
      is_map(map[:result]) -> dig_tools(map[:result])
      true -> []
    end
  end

  defp dig_tools(_other), do: []
end
