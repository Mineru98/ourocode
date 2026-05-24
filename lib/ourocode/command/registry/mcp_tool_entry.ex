defmodule Ourocode.Command.Registry.McpToolEntry do
  @moduledoc false

  @spec build(map(), map()) :: map() | nil
  def build(tool, context) when is_map(tool) and is_map(context) do
    tool_name =
      tool
      |> field("name", "")
      |> to_string()
      |> String.trim()

    if tool_name == "" do
      nil
    else
      display_name =
        tool
        |> field("title", field(tool, "display_name", tool_name))
        |> to_string()
        |> String.trim()

      name = slugify_name(display_name)
      slash = tool |> field("slash", name) |> normalize_slash()
      transport = Map.fetch!(context, :transport)
      source_id = Map.fetch!(context, :source_id)

      source_attribution = %{
        source: :mcp,
        source_id: source_id,
        transport: transport,
        server_id: source_id,
        discovered_from: Map.get(context, :discovered_from)
      }

      invocability = invocability_metadata(tool)

      %{
        id: "mcp:#{source_id}:#{tool_name}",
        name: name,
        slash: slash,
        source: :mcp,
        source_id: source_id,
        source_attribution: source_attribution,
        type: :slash_command,
        category: :mcp,
        summary: tool |> field("description", "") |> to_string(),
        aliases: aliases(tool),
        args: args(tool),
        availability: :available,
        runnable?: true,
        run_spec: %{
          kind: :mcp_tool,
          transport: transport,
          server_id: source_id,
          tool_name: tool_name,
          method: "tools/call",
          invocability: invocability
        },
        metadata: %{
          transport: transport,
          server_id: source_id,
          tool_name: tool_name,
          invocability: invocability,
          input_schema: field(tool, "inputSchema", field(tool, "input_schema", %{})),
          annotations: field(tool, "annotations", %{}),
          discovered_from: Map.get(context, :discovered_from),
          source_attribution: source_attribution
        }
      }
    end
  end

  @spec envelope_context(map()) :: map()
  def envelope_context(envelope) when is_map(envelope) do
    transport =
      envelope
      |> field("transport", :unknown)
      |> normalize_transport()

    source_id =
      envelope
      |> field("source_id", field(envelope, "server_id", field(envelope, "session_id", "mcp")))
      |> to_string()

    %{
      transport: transport,
      source_id: source_id,
      discovered_from: field(envelope, "discovered_from", "transport")
    }
  end

  @spec tool_list(map()) :: [map()] | nil
  def tool_list(envelope) when is_map(envelope) do
    cond do
      is_list(field(envelope, "tools", nil)) -> field(envelope, "tools", nil)
      is_list(field(envelope, "entries", nil)) -> field(envelope, "entries", nil)
      is_list(get_in(envelope, ["result", "tools"])) -> get_in(envelope, ["result", "tools"])
      is_list(get_in(envelope, [:result, :tools])) -> get_in(envelope, [:result, :tools])
      true -> nil
    end
  end

  @spec tool_entry?(term()) :: boolean()
  def tool_entry?(entry) when is_map(entry) do
    is_binary(field(entry, "name", nil)) and
      (Map.has_key?(entry, "inputSchema") or Map.has_key?(entry, :inputSchema) or
         Map.has_key?(entry, "input_schema") or Map.has_key?(entry, :input_schema) or
         field(entry, "kind", "tool") in ["tool", :tool])
  end

  def tool_entry?(_entry), do: false

  @spec user_invocable?(term()) :: boolean()
  def user_invocable?(entry) when is_map(entry) do
    annotations = field(entry, "annotations", %{})

    field(
      entry,
      "user_invocable",
      field(
        entry,
        "userInvocable",
        field(annotations, "user_invocable", field(annotations, "userInvocable", true))
      )
    )
    |> truthy_default_true?()
  end

  def user_invocable?(_entry), do: false

  defp aliases(tool) do
    tool
    |> field("aliases", [])
    |> List.wrap()
    |> Enum.map(&normalize_slash(to_string(&1)))
  end

  defp args(tool) when is_map(tool) do
    schema = field(tool, "inputSchema", field(tool, "input_schema", %{}))
    properties = field(schema, "properties", %{})
    required = schema |> field("required", []) |> List.wrap() |> MapSet.new(&to_string/1)

    cond do
      is_map(properties) and map_size(properties) > 0 ->
        properties
        |> Enum.map(fn {name, definition} ->
          name = to_string(name)

          %{
            name: name,
            required?: MapSet.member?(required, name),
            description: definition |> field("description", "") |> to_string()
          }
        end)
        |> Enum.sort_by(& &1.name)

      is_list(field(tool, "args", [])) ->
        tool
        |> field("args", [])
        |> Enum.map(&normalize_arg!/1)

      true ->
        []
    end
  end

  defp normalize_arg!(%{name: name, required?: required?, description: description}) do
    %{name: name, required?: required?, description: description}
  end

  defp normalize_arg!(arg) when is_map(arg) do
    %{
      name: arg |> field("name", "") |> to_string(),
      required?: arg |> field("required?", field(arg, "required", false)) |> truthy?(),
      description: arg |> field("description", "") |> to_string()
    }
  end

  defp invocability_metadata(entry) when is_map(entry) do
    annotations = field(entry, "annotations", %{})

    cond do
      explicit = invocability_value(entry, "user_invocable") ->
        invocability_metadata(:tool_user_invocable, explicit)

      explicit = invocability_value(entry, "userInvocable") ->
        invocability_metadata(:tool_user_invocable, explicit)

      explicit = invocability_value(annotations, "user_invocable") ->
        invocability_metadata(:annotation_user_invocable, explicit)

      explicit = invocability_value(annotations, "userInvocable") ->
        invocability_metadata(:annotation_user_invocable, explicit)

      true ->
        invocability_metadata(:default_user_invocable, true)
    end
  end

  defp invocability_metadata(source, raw_value) do
    %{
      user_invocable?: truthy_default_true?(raw_value),
      source: source,
      raw_value: raw_value,
      runnable?: true,
      method: "tools/call"
    }
  end

  defp invocability_value(entry, key) when is_map(entry) do
    cond do
      Map.has_key?(entry, key) -> Map.get(entry, key)
      Map.has_key?(entry, atom_key(key)) -> Map.get(entry, atom_key(key))
      true -> nil
    end
  end

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, atom_key(key), default))
  end

  defp atom_key(key) when is_atom(key), do: key

  defp atom_key("aliases"), do: :aliases
  defp atom_key("args"), do: :args
  defp atom_key("annotations"), do: :annotations
  defp atom_key("description"), do: :description
  defp atom_key("discovered_from"), do: :discovered_from
  defp atom_key("display_name"), do: :display_name
  defp atom_key("entries"), do: :entries
  defp atom_key("input_schema"), do: :input_schema
  defp atom_key("inputSchema"), do: :inputSchema
  defp atom_key("kind"), do: :kind
  defp atom_key("name"), do: :name
  defp atom_key("properties"), do: :properties
  defp atom_key("required"), do: :required
  defp atom_key("required?"), do: :required?
  defp atom_key("server_id"), do: :server_id
  defp atom_key("session_id"), do: :session_id
  defp atom_key("slash"), do: :slash
  defp atom_key("source_id"), do: :source_id
  defp atom_key("title"), do: :title
  defp atom_key("tools"), do: :tools
  defp atom_key("transport"), do: :transport
  defp atom_key("user_invocable"), do: :user_invocable
  defp atom_key("userInvocable"), do: :userInvocable
  defp atom_key(_key), do: :__missing_mcp_tool_entry_key__

  defp normalize_slash(command) when is_binary(command) do
    command = String.trim(command)

    if String.starts_with?(command, "/") do
      command
    else
      "/#{command}"
    end
  end

  defp slugify_name(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp normalize_transport("streamable_http"), do: :streamable_http
  defp normalize_transport("streamable-http"), do: :streamable_http
  defp normalize_transport("stdio"), do: :stdio
  defp normalize_transport("sse"), do: :sse
  defp normalize_transport(transport) when is_atom(transport), do: transport
  defp normalize_transport(transport) when is_binary(transport), do: transport
  defp normalize_transport(_transport), do: :unknown

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp truthy_default_true?(false), do: false
  defp truthy_default_true?("false"), do: false
  defp truthy_default_true?(_value), do: true
end
