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
  alias Ourocode.Plugin.MappingRegistry
  alias Ourocode.Plugin.RendererMappingLoader

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
      local = MappingRegistry.normalize(local_registry)
      user = MappingRegistry.normalize(user_registry)

      {:ok,
       %{
         plugin: plugin,
         registry: MappingRegistry.overlay([official, local, user]),
         layers: %{official: official, local: local, user: user},
         sources: MappingRegistry.sources(official, local, user),
         overridden: MappingRegistry.overridden(official, local, user)
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
      active = MappingRegistry.normalize(active_registry)

      additions = %{
        adapters: MappingRegistry.missing_entries(active.adapters, loaded.adapters),
        renderers: MappingRegistry.missing_entries(active.renderers, loaded.renderers),
        actions: MappingRegistry.missing_entries(active.actions, loaded.actions)
      }

      skipped_existing = %{
        adapters: MappingRegistry.existing_entries(active.adapters, loaded.adapters),
        renderers: MappingRegistry.existing_entries(active.renderers, loaded.renderers),
        actions: MappingRegistry.existing_entries(active.actions, loaded.actions)
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
end
