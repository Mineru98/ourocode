defmodule Ourocode.Plugin.RendererMappingLoader do
  @moduledoc """
  Loads declarative pane renderer mappings from trusted official plugins.

  Renderer mappings are data-only plugin strategy entries. Official mappings
  must be signed and are verified before use after the containing plugin passes
  allowed-path, capability-manifest, checksum, and trust checks, and only for
  the canonical official `ouroboros-plugin`.
  """

  alias Ourocode.Plugin.LoadError
  alias Ourocode.Plugin.Loader
  alias Ourocode.Plugin.MappingSignatureVerifier

  @official_plugin_id "ouroboros-plugin"

  @renderer_keys %{
    "parent_mcp" => :parent_mcp,
    "parent_mcp_call" => :parent_mcp,
    "child_session" => :child_session,
    "session_list" => :session_list,
    "task_prompt" => :task_prompt,
    "wonder_tool" => :wonder_tool,
    "wonderTool" => :wonder_tool
  }

  @type renderer_key :: atom()
  @type loaded_mappings :: %{
          required(:plugin) => Loader.loaded_plugin(),
          required(:renderer_mappings) => list(map()),
          required(:renderers) => %{optional(renderer_key()) => module()}
        }

  @doc """
  Loads the default declarative renderer mapping set for a plugin.

  The default source is the capability manifest's `renderer_mappings` array.
  Each entry must contain a whitelisted `key` and an already-loaded renderer
  `module` that implements `render/1`.
  """
  @spec load_default(Path.t(), keyword()) :: {:ok, loaded_mappings()} | {:error, LoadError.t()}
  def load_default(plugin_path, opts \\ []) when is_binary(plugin_path) and is_list(opts) do
    with {:ok, plugin} <- Loader.load(plugin_path, opts),
         :ok <- ensure_official_plugin(plugin),
         {:ok, mappings} <- fetch_mappings(plugin),
         :ok <- verify_mapping_signatures(plugin, mappings, opts) do
      case build_renderer_registry(mappings) do
        {:ok, renderers} ->
          {:ok, %{plugin: plugin, renderer_mappings: mappings, renderers: renderers}}

        {:error, reason} ->
          {:error, load_error(reason, plugin)}
      end
    else
      {:error, %LoadError{} = error} ->
        {:error, error}

      {:error, reason, %{} = plugin} ->
        {:error, load_error(reason, plugin)}
    end
  end

  defp ensure_official_plugin(%{
         plugin_id: @official_plugin_id,
         trust_classification: "official_trusted"
       }) do
    :ok
  end

  defp ensure_official_plugin(plugin), do: {:error, :untrusted_renderer_mapping_plugin, plugin}

  defp fetch_mappings(%{capability_manifest: %{"renderer_mappings" => mappings}} = plugin)
       when is_list(mappings) do
    if Enum.all?(mappings, &valid_mapping_shape?/1) do
      {:ok, mappings}
    else
      {:error, :invalid_renderer_mapping_manifest, plugin}
    end
  end

  defp fetch_mappings(%{capability_manifest: manifest} = plugin) when is_map(manifest) do
    case Map.get(manifest, "renderer_mappings", []) do
      [] -> {:ok, []}
      _other -> {:error, :invalid_renderer_mapping_manifest, plugin}
    end
  end

  defp verify_mapping_signatures(plugin, mappings, opts) do
    case MappingSignatureVerifier.verify_all(:renderer, plugin, mappings, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, plugin}
    end
  end

  defp valid_mapping_shape?(%{"key" => key, "module" => module_name})
       when is_binary(key) and is_binary(module_name) do
    true
  end

  defp valid_mapping_shape?(_mapping), do: false

  defp build_renderer_registry(mappings) do
    Enum.reduce_while(mappings, {:ok, %{}}, fn mapping, {:ok, renderers} ->
      with {:ok, key} <- parse_renderer_key(mapping["key"]),
           {:ok, module} <- parse_renderer_module(mapping["module"]) do
        {:cont, {:ok, Map.put(renderers, key, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_renderer_key(key) do
    case Map.fetch(@renderer_keys, key) do
      {:ok, renderer_key} -> {:ok, renderer_key}
      :error -> {:error, :invalid_renderer_mapping_key}
    end
  end

  defp parse_renderer_module(module_name) do
    module_name
    |> normalize_module_name()
    |> existing_module()
    |> case do
      {:ok, module} ->
        if function_exported?(module, :render, 1) do
          {:ok, module}
        else
          {:error, :invalid_renderer_mapping_module}
        end

      :error ->
        {:error, :invalid_renderer_mapping_module}
    end
  end

  defp normalize_module_name("Elixir." <> _rest = module_name), do: module_name
  defp normalize_module_name(module_name), do: "Elixir." <> module_name

  defp existing_module(module_name) do
    try do
      {:ok, String.to_existing_atom(module_name)}
    rescue
      ArgumentError -> :error
    end
  end

  defp load_error(reason, %{plugin_path: plugin_path, capability_manifest_path: manifest_path}) do
    LoadError.exception(reason: reason, plugin_path: plugin_path, manifest_path: manifest_path)
  end
end
