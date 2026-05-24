defmodule Ourocode.Plugin.MappingRegistry do
  @moduledoc """
  Normalizes and composes plugin mapping registries.

  Mapping loaders emit canonical keys for official plugin declarations, while
  live/local/user registries can still contain legacy string aliases. This
  module keeps alias normalization and precedence accounting in one pure layer
  so resolver modules only deal with I/O and loader errors.
  """

  @simple_adapter_keys %{
    "runtime" => :runtime,
    "ouroboros_workflow" => :ouroboros_workflow,
    "mcp_flow" => :mcp_flow,
    "codex" => :codex,
    "opencode" => :opencode,
    "claude_code" => :claude_code,
    "ouroboros" => :ouroboros,
    "mcp" => :mcp,
    "ouroboros_interview" => :ouroboros_interview,
    "ouroboros_seed" => :ouroboros_seed,
    "ouroboros_run" => :ouroboros_run,
    "ouroboros_evolve" => :ouroboros_evolve,
    "ouroboros_ralph" => :ouroboros_ralph,
    "ouroboros_workflow_action" => :ouroboros_workflow,
    "mcp_stdio" => :mcp_stdio,
    "mcp_streamable_http" => :mcp_streamable_http,
    "mcp_sse" => :mcp_sse
  }

  @adapter_tuple_key_heads %{
    "ouroboros_workflow" => :ouroboros_workflow,
    "ouroboros" => :ouroboros,
    "mcp_flow" => :mcp_flow,
    "mcp" => :mcp
  }

  @adapter_tuple_key_values %{
    "interview" => :interview,
    "seed" => :seed,
    "run" => :run,
    "evolve" => :evolve,
    "ralph" => :ralph,
    "workflow" => :workflow,
    "stdio" => :stdio,
    "streamable_http" => :streamable_http,
    "sse" => :sse
  }

  @renderer_keys %{
    "parent_mcp" => :parent_mcp,
    "parent_mcp_call" => :parent_mcp,
    "child_session" => :child_session,
    "session_list" => :session_list,
    "task_prompt" => :task_prompt,
    "wonder_tool" => :wonder_tool,
    "wonderTool" => :wonder_tool
  }

  @action_keys %{
    "session.focus" => {:session, :focus},
    "session.open" => {:session, :open},
    "child_session.focus" => {:child_session, :focus},
    "child_session.open" => {:child_session, :open},
    "parent_call.focus" => {:parent_call, :focus},
    "parent_call.open" => {:parent_call, :open},
    "pane.focus" => {:pane, :focus},
    "pane.open" => {:pane, :open},
    "wonder_tool.decide" => {:wonder_tool, :decide},
    "wonderTool.decide" => {:wonder_tool, :decide},
    "session_focus" => :session_focus,
    "session_open" => :session_open,
    "child_session_focus" => :child_session_focus,
    "child_session_open" => :child_session_open,
    "pane_focus" => :pane_focus,
    "pane_open" => :pane_open,
    "wonder_tool_decide" => :wonder_tool_decide,
    "wonderTool_decide" => :wonder_tool_decide
  }

  @type registry :: %{
          required(:adapters) => map(),
          required(:renderers) => map(),
          required(:actions) => map()
        }

  @type source_registry :: %{
          required(:adapters) => %{optional(term()) => :official | :local | :user},
          required(:renderers) => %{optional(term()) => :official | :local | :user},
          required(:actions) => %{optional(term()) => :official | :local | :user}
        }

  @doc "Returns an empty normalized mapping registry."
  @spec empty() :: registry()
  def empty, do: %{adapters: %{}, renderers: %{}, actions: %{}}

  @doc "Normalizes registry sections and legacy string aliases."
  @spec normalize(map() | keyword() | term()) :: registry()
  def normalize(registry) when is_list(registry) do
    registry |> Map.new() |> normalize()
  end

  def normalize(registry) when is_map(registry) do
    %{
      adapters: registry |> registry_section(:adapters) |> normalize_active_adapter_keys(),
      renderers:
        registry |> registry_section(:renderers) |> normalize_active_mapping_keys(@renderer_keys),
      actions:
        registry |> registry_section(:actions) |> normalize_active_mapping_keys(@action_keys)
    }
  end

  def normalize(_registry), do: empty()

  @doc "Applies registries in order, allowing later registries to override earlier ones."
  @spec overlay([registry()]) :: registry()
  def overlay(registries) do
    Enum.reduce(registries, empty(), fn registry, active ->
      %{
        adapters: Map.merge(active.adapters, registry.adapters),
        renderers: Map.merge(active.renderers, registry.renderers),
        actions: Map.merge(active.actions, registry.actions)
      }
    end)
  end

  @doc "Builds a registry whose values identify the source that won each active key."
  @spec sources(registry(), registry(), registry()) :: source_registry()
  def sources(official, local, user) do
    official_sources = source_entries(official, :official)
    local_sources = source_entries(local, :local)
    user_sources = source_entries(user, :user)

    overlay([official_sources, local_sources, user_sources])
  end

  @doc "Returns lower-priority entries that lost to higher-priority registries."
  @spec overridden(registry(), registry(), registry()) :: %{
          required(:official) => registry(),
          required(:local) => registry(),
          required(:user) => registry()
        }
  def overridden(official, local, user) do
    %{
      official: overridden_by_higher_priority(official, overlay([local, user])),
      local: overridden_by_higher_priority(local, user),
      user: empty()
    }
  end

  @doc "Returns loaded entries that are absent from the active registry."
  @spec missing_entries(map(), map()) :: map()
  def missing_entries(active, loaded) do
    Map.reject(loaded, fn {key, _module} -> Map.has_key?(active, key) end)
  end

  @doc "Returns loaded entries whose keys already exist in the active registry."
  @spec existing_entries(map(), map()) :: map()
  def existing_entries(active, loaded) do
    Map.take(loaded, Map.keys(active))
  end

  defp registry_section(registry, section) do
    Map.get(registry, section, Map.get(registry, Atom.to_string(section), %{}))
  end

  defp normalize_active_adapter_keys(entries) do
    Enum.reduce(entries, %{}, fn {key, module}, registry ->
      Map.put(registry, normalize_adapter_key(key), module)
    end)
  end

  defp normalize_active_mapping_keys(entries, key_map) do
    Enum.reduce(entries, %{}, fn {key, module}, registry ->
      Map.put(registry, Map.get(key_map, key, key), module)
    end)
  end

  defp normalize_adapter_key(key) when is_binary(key) do
    cond do
      Map.has_key?(@simple_adapter_keys, key) ->
        Map.fetch!(@simple_adapter_keys, key)

      String.contains?(key, ".") ->
        normalize_tuple_adapter_key(key)

      true ->
        key
    end
  end

  defp normalize_adapter_key(key), do: key

  defp normalize_tuple_adapter_key(key) do
    case String.split(key, ".", parts: 2) do
      [head, value] ->
        with {:ok, head_key} <- Map.fetch(@adapter_tuple_key_heads, head),
             {:ok, value_key} <- Map.fetch(@adapter_tuple_key_values, value) do
          {head_key, value_key}
        else
          :error -> key
        end

      _other ->
        key
    end
  end

  defp source_entries(registry, source) do
    %{
      adapters: Map.new(registry.adapters, fn {key, _module} -> {key, source} end),
      renderers: Map.new(registry.renderers, fn {key, _module} -> {key, source} end),
      actions: Map.new(registry.actions, fn {key, _module} -> {key, source} end)
    }
  end

  defp overridden_by_higher_priority(registry, higher_priority_registry) do
    %{
      adapters: Map.take(registry.adapters, Map.keys(higher_priority_registry.adapters)),
      renderers: Map.take(registry.renderers, Map.keys(higher_priority_registry.renderers)),
      actions: Map.take(registry.actions, Map.keys(higher_priority_registry.actions))
    }
  end
end
