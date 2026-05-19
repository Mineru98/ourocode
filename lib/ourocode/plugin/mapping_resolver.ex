defmodule Ourocode.Plugin.MappingResolver do
  @moduledoc """
  Resolves plugin mappings into the active strategy registry.

  The resolver is intentionally a merge layer over the individual declarative
  mapping loaders. Each loader owns security validation and type-specific
  parsing; this module only composes their registries with deterministic
  precedence and fills missing active entries without replacing
  already-installed local strategies for the legacy merge API.
  """

  alias Ourocode.Plugin.ActionMappingLoader
  alias Ourocode.Plugin.AdapterMappingLoader
  alias Ourocode.Plugin.LoadError
  alias Ourocode.Plugin.RendererMappingLoader

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

  @type active_registry :: %{
          optional(:adapters) => map(),
          optional(:renderers) => map(),
          optional(:actions) => map()
        }

  @type source_registry :: %{
          optional(:adapters) => %{optional(term()) => :official | :local | :user},
          optional(:renderers) => %{optional(term()) => :official | :local | :user},
          optional(:actions) => %{optional(term()) => :official | :local | :user}
        }

  @type merge_result :: %{
          required(:plugin) => map(),
          required(:registry) => active_registry(),
          required(:additions) => active_registry(),
          required(:skipped_existing) => active_registry(),
          required(:loaded) => active_registry()
        }

  @type resolve_result :: %{
          required(:plugin) => map(),
          required(:registry) => active_registry(),
          required(:layers) => %{
            required(:official) => active_registry(),
            required(:local) => active_registry(),
            required(:user) => active_registry()
          },
          required(:sources) => source_registry(),
          required(:overridden) => %{
            required(:official) => active_registry(),
            required(:local) => active_registry(),
            required(:user) => active_registry()
          }
        }

  @doc """
  Loads official mappings and resolves the active registry.

  Precedence is deterministic and intentionally simple:

  1. official `ouroboros-plugin` declarative mappings provide defaults
  2. local mappings override official defaults
  3. user mappings override both local and official mappings

  The returned `sources` registry mirrors the active keys and records the
  winning source (`:official`, `:local`, or `:user`) for each mapping. The
  `overridden` registry records losing lower-priority entries by their source.
  """
  @spec resolve_active_registry(
          Path.t(),
          active_registry() | keyword(),
          active_registry() | keyword(),
          keyword()
        ) ::
          {:ok, resolve_result()} | {:error, LoadError.t()}
  def resolve_active_registry(plugin_path, user_registry, local_registry, opts \\ [])
      when is_binary(plugin_path) and is_list(opts) do
    with {:ok, %{plugin: plugin, loaded: official}} <- load_official_registry(plugin_path, opts) do
      local = normalize_registry(local_registry)
      user = normalize_registry(user_registry)

      {:ok,
       %{
         plugin: plugin,
         registry: overlay_registries([official, local, user]),
         layers: %{official: official, local: local, user: user},
         sources: source_registry(official, local, user),
         overridden: overridden_registry(official, local, user)
       }}
    end
  end

  @doc """
  Loads official plugin mappings and merges entries missing from `active_registry`.

  Existing local entries always win. This keeps a live strategy switch from
  overwriting an explicitly installed adapter, renderer, or action while still
  allowing the official plugin to backfill missing defaults.
  """
  @spec merge_official_mappings(Path.t(), active_registry() | keyword(), keyword()) ::
          {:ok, merge_result()} | {:error, LoadError.t()}
  def merge_official_mappings(plugin_path, active_registry, opts \\ [])
      when is_binary(plugin_path) and is_list(opts) do
    with {:ok, %{plugin: plugin, loaded: loaded}} <- load_official_registry(plugin_path, opts) do
      active = normalize_registry(active_registry)

      additions = %{
        adapters: missing_entries(active.adapters, loaded.adapters),
        renderers: missing_entries(active.renderers, loaded.renderers),
        actions: missing_entries(active.actions, loaded.actions)
      }

      skipped_existing = %{
        adapters: existing_entries(active.adapters, loaded.adapters),
        renderers: existing_entries(active.renderers, loaded.renderers),
        actions: existing_entries(active.actions, loaded.actions)
      }

      {:ok,
       %{
         plugin: plugin,
         registry: %{
           adapters: Map.merge(additions.adapters, active.adapters),
           renderers: Map.merge(additions.renderers, active.renderers),
           actions: Map.merge(additions.actions, active.actions)
         },
         additions: additions,
         skipped_existing: skipped_existing,
         loaded: loaded
       }}
    end
  end

  defp load_official_registry(plugin_path, opts) do
    with {:ok, adapter_result} <- AdapterMappingLoader.load_default(plugin_path, opts),
         {:ok, renderer_result} <- RendererMappingLoader.load_default(plugin_path, opts),
         {:ok, action_result} <- ActionMappingLoader.load_default(plugin_path, opts) do
      {:ok,
       %{
         plugin: adapter_result.plugin,
         loaded: %{
           adapters: adapter_result.adapters,
           renderers: renderer_result.renderers,
           actions: action_result.actions
         }
       }}
    end
  end

  defp normalize_registry(registry) when is_list(registry) do
    registry |> Map.new() |> normalize_registry()
  end

  defp normalize_registry(registry) when is_map(registry) do
    %{
      adapters: registry |> registry_section(:adapters) |> normalize_active_adapter_keys(),
      renderers:
        registry |> registry_section(:renderers) |> normalize_active_mapping_keys(@renderer_keys),
      actions: registry |> registry_section(:actions) |> normalize_active_mapping_keys(@action_keys)
    }
  end

  defp normalize_registry(_registry), do: %{adapters: %{}, renderers: %{}, actions: %{}}

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

  defp overlay_registries(registries) do
    Enum.reduce(registries, empty_registry(), fn registry, active ->
      %{
        adapters: Map.merge(active.adapters, registry.adapters),
        renderers: Map.merge(active.renderers, registry.renderers),
        actions: Map.merge(active.actions, registry.actions)
      }
    end)
  end

  defp source_registry(official, local, user) do
    official_sources = source_entries(official, :official)
    local_sources = source_entries(local, :local)
    user_sources = source_entries(user, :user)

    overlay_registries([official_sources, local_sources, user_sources])
  end

  defp source_entries(registry, source) do
    %{
      adapters: Map.new(registry.adapters, fn {key, _module} -> {key, source} end),
      renderers: Map.new(registry.renderers, fn {key, _module} -> {key, source} end),
      actions: Map.new(registry.actions, fn {key, _module} -> {key, source} end)
    }
  end

  defp overridden_registry(official, local, user) do
    %{
      official: overridden_by_higher_priority(official, overlay_registries([local, user])),
      local: overridden_by_higher_priority(local, user),
      user: empty_registry()
    }
  end

  defp overridden_by_higher_priority(registry, higher_priority_registry) do
    %{
      adapters: Map.take(registry.adapters, Map.keys(higher_priority_registry.adapters)),
      renderers: Map.take(registry.renderers, Map.keys(higher_priority_registry.renderers)),
      actions: Map.take(registry.actions, Map.keys(higher_priority_registry.actions))
    }
  end

  defp empty_registry, do: %{adapters: %{}, renderers: %{}, actions: %{}}

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

  defp missing_entries(active, loaded) do
    Map.reject(loaded, fn {key, _module} -> Map.has_key?(active, key) end)
  end

  defp existing_entries(active, loaded) do
    Map.take(loaded, Map.keys(active))
  end
end
