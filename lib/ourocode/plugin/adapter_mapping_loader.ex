defmodule Ourocode.Plugin.AdapterMappingLoader do
  @moduledoc """
  Loads declarative runtime adapter mappings from trusted official plugins.

  Adapter mappings are data-only plugin strategy entries. Official mappings
  must be signed and are verified before use after the containing plugin passes
  allowed-path, capability-manifest, checksum, and trust checks.
  """

  alias Ourocode.Plugin.LoadError
  alias Ourocode.Plugin.Loader
  alias Ourocode.Plugin.MappingSignatureVerifier

  @official_plugin_id "ouroboros-plugin"

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

  @tuple_key_heads %{
    "ouroboros_workflow" => :ouroboros_workflow,
    "ouroboros" => :ouroboros,
    "mcp_flow" => :mcp_flow,
    "mcp" => :mcp
  }

  @tuple_key_values %{
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

  @type adapter_key :: atom() | {atom(), atom()}
  @type loaded_mappings :: %{
          required(:plugin) => Loader.loaded_plugin(),
          required(:adapter_mappings) => list(map()),
          required(:adapters) => %{optional(adapter_key()) => module()}
        }

  @doc """
  Loads the default declarative adapter mapping set for a plugin.

  The default source is the capability manifest's `adapter_mappings` array. Each
  entry must contain a whitelisted `key` and an already-loaded adapter `module`
  that implements `execute/2`.
  """
  @spec load_default(Path.t(), keyword()) :: {:ok, loaded_mappings()} | {:error, LoadError.t()}
  def load_default(plugin_path, opts \\ []) when is_binary(plugin_path) and is_list(opts) do
    with {:ok, plugin} <- Loader.load(plugin_path, opts),
         :ok <- ensure_official_plugin(plugin),
         {:ok, mappings} <- fetch_mappings(plugin),
         :ok <- verify_mapping_signatures(plugin, mappings, opts) do
      case build_adapter_registry(mappings) do
        {:ok, adapters} ->
          {:ok, %{plugin: plugin, adapter_mappings: mappings, adapters: adapters}}

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

  defp ensure_official_plugin(plugin), do: {:error, :untrusted_adapter_mapping_plugin, plugin}

  defp fetch_mappings(%{capability_manifest: %{"adapter_mappings" => mappings}} = plugin)
       when is_list(mappings) do
    if Enum.all?(mappings, &valid_mapping_shape?/1) do
      {:ok, mappings}
    else
      {:error, :invalid_adapter_mapping_manifest, plugin}
    end
  end

  defp fetch_mappings(%{capability_manifest: manifest} = plugin) when is_map(manifest) do
    case Map.get(manifest, "adapter_mappings", []) do
      [] -> {:ok, []}
      _other -> {:error, :invalid_adapter_mapping_manifest, plugin}
    end
  end

  defp verify_mapping_signatures(plugin, mappings, opts) do
    case MappingSignatureVerifier.verify_all(:adapter, plugin, mappings, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, plugin}
    end
  end

  defp valid_mapping_shape?(%{"key" => key, "module" => module_name})
       when is_binary(key) and is_binary(module_name) do
    true
  end

  defp valid_mapping_shape?(_mapping), do: false

  defp build_adapter_registry(mappings) do
    Enum.reduce_while(mappings, {:ok, %{}}, fn mapping, {:ok, adapters} ->
      with {:ok, key} <- parse_adapter_key(mapping["key"]),
           {:ok, module} <- parse_adapter_module(mapping["module"]) do
        {:cont, {:ok, Map.put(adapters, key, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_adapter_key(key) do
    cond do
      Map.has_key?(@simple_adapter_keys, key) ->
        {:ok, Map.fetch!(@simple_adapter_keys, key)}

      String.contains?(key, ".") ->
        parse_tuple_adapter_key(key)

      true ->
        {:error, :invalid_adapter_mapping_key}
    end
  end

  defp parse_tuple_adapter_key(key) do
    case String.split(key, ".", parts: 2) do
      [head, value] ->
        with {:ok, head_key} <- fetch_allowed_key(@tuple_key_heads, head),
             {:ok, value_key} <- fetch_allowed_key(@tuple_key_values, value) do
          {:ok, {head_key, value_key}}
        end

      _other ->
        {:error, :invalid_adapter_mapping_key}
    end
  end

  defp fetch_allowed_key(allowed, value) do
    case Map.fetch(allowed, value) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :invalid_adapter_mapping_key}
    end
  end

  defp parse_adapter_module(module_name) do
    module_name
    |> normalize_module_name()
    |> existing_module()
    |> case do
      {:ok, module} ->
        if function_exported?(module, :execute, 2) do
          {:ok, module}
        else
          {:error, :invalid_adapter_mapping_module}
        end

      :error ->
        {:error, :invalid_adapter_mapping_module}
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
