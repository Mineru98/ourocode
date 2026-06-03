defmodule Ourocode.WonderTool.Bridge do
  @moduledoc """
  Promotes MCP-internal user interactions into wonderTool decision payloads.

  ACP/Grok-like agents can emit permission or user-input requests as ordinary
  stream notifications. The bridge converts those protocol-level requests into
  the same wonderTool shape the local UI already knows how to render and answer.
  """

  alias Ourocode.MCP.ChildSessionCreationParser

  @permission_methods MapSet.new([
                        "session/request_permission",
                        "session/requestPermission",
                        "request_permission",
                        "requestPermission"
                      ])

  @doc """
  Returns a wonderTool-compatible payload for supported MCP interaction events.
  """
  @spec to_detection_payload(map()) :: {:ok, map()} | :ignore
  def to_detection_payload(event) when is_map(event) do
    notification = notification(event)
    method = string_value(notification, ["method", :method])
    params = map_value(notification, ["params", :params]) || %{}

    cond do
      MapSet.member?(@permission_methods, method) ->
        {:ok, permission_payload(event, params)}

      true ->
        :ignore
    end
  end

  def to_detection_payload(_event), do: :ignore

  defp permission_payload(event, params) do
    request_id =
      string_value(params, ["request_id", "requestId", "id", :request_id, :requestId, :id]) ||
        string_value(event, [:request_id, "request_id"]) ||
        request_id_from_parent(event)

    parent_call_id = string_value(event, [:parent_call_id, "parent_call_id"])
    child_id = child_id(event, params)

    %{
      "tool" => "wonderTool",
      "kind" => "permission",
      "requestId" => request_id,
      "parentCallId" => parent_call_id,
      "childID" => child_id,
      "externalIds" => external_ids(event),
      "questions" => [
        %{
          "id" => "permission",
          "header" => "Permission",
          "question" => permission_question(params),
          "kind" => "permission",
          "options" => permission_options(params)
        }
      ]
    }
    |> drop_nil_values()
  end

  defp permission_question(params) do
    string_value(params, [
      "question",
      "prompt",
      "description",
      "message",
      :question,
      :prompt,
      :description,
      :message
    ]) ||
      action_question(params) ||
      "Allow this MCP action?"
  end

  defp action_question(params) do
    case string_value(params, ["action", "command", "tool", :action, :command, :tool]) do
      nil -> nil
      action -> "Allow " <> action <> "?"
    end
  end

  defp permission_options(params) do
    case list_value(params, ["options", "choices", :options, :choices]) do
      options when is_list(options) and length(options) >= 2 ->
        Enum.map(options, &normalize_option/1)

      _options ->
        [
          %{"label" => "Allow (Recommended)", "description" => "Approve this MCP action."},
          %{"label" => "Deny", "description" => "Decline and return control to the agent."}
        ]
    end
  end

  defp normalize_option(option) when is_map(option) do
    %{
      "label" =>
        string_value(option, ["label", "name", "value", :label, :name, :value]) || "Option",
      "description" =>
        string_value(option, ["description", "detail", "summary", :description, :detail, :summary]) ||
          string_value(option, ["label", "name", "value", :label, :name, :value]) ||
          "Select this option."
    }
  end

  defp normalize_option(option) when is_binary(option) do
    %{"label" => option, "description" => option}
  end

  defp normalize_option(_option),
    do: %{"label" => "Option", "description" => "Select this option."}

  defp child_id(event, params) do
    case ChildSessionCreationParser.extract_child_id(Map.put(event, :params, params)) do
      {:ok, child_id} -> child_id
      :ignore -> nil
    end
  end

  defp external_ids(event) do
    case Map.get(event, :external_ids) || Map.get(event, "external_ids") do
      external_ids when is_map(external_ids) -> external_ids
      _value -> nil
    end
  end

  defp notification(event) do
    case Map.get(event, :notification) || Map.get(event, "notification") do
      notification when is_map(notification) -> notification
      _value -> event
    end
  end

  defp request_id_from_parent(event) do
    case string_value(event, [:parent_call_id, "parent_call_id"]) do
      nil -> "mcp-permission"
      parent_call_id -> parent_call_id <> "-permission"
    end
  end

  defp string_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> nil
            trimmed -> trimmed
          end

        value when is_atom(value) and not is_nil(value) ->
          Atom.to_string(value)

        value when is_integer(value) ->
          Integer.to_string(value)

        _value ->
          nil
      end
    end)
  end

  defp string_value(_map, _keys), do: nil

  defp map_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_map(value) -> value
        _value -> nil
      end
    end)
  end

  defp list_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_list(value) -> value
        _value -> nil
      end
    end)
  end

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
