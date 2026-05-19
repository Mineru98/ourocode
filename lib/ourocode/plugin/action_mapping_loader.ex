defmodule Ourocode.Plugin.ActionMappingLoader do
  @moduledoc """
  Loads declarative UI/steering action mappings from trusted official plugins.

  Action mappings are data-only plugin strategy entries. Official mappings must
  be signed and are verified before use after the containing plugin passes
  allowed-path, capability-manifest, checksum, and trust checks, and only for
  the canonical official `ouroboros-plugin`.
  """

  alias Ourocode.Plugin.LoadError
  alias Ourocode.Plugin.Loader
  alias Ourocode.Plugin.MappingSignatureVerifier

  @official_plugin_id "ouroboros-plugin"

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

  @type action_key :: atom() | {atom(), atom()}
  @type loaded_mappings :: %{
          required(:plugin) => Loader.loaded_plugin(),
          required(:action_mappings) => list(map()),
          required(:actions) => %{optional(action_key()) => module()}
        }

  @doc """
  Loads the default declarative action mapping set for a plugin.

  The default source is the capability manifest's `action_mappings` array.
  Each entry must contain a whitelisted `key` and an already-loaded action
  `module` that implements `execute/2`.
  """
  @spec load_default(Path.t(), keyword()) :: {:ok, loaded_mappings()} | {:error, LoadError.t()}
  def load_default(plugin_path, opts \\ []) when is_binary(plugin_path) and is_list(opts) do
    with {:ok, plugin} <- Loader.load(plugin_path, opts),
         :ok <- ensure_official_plugin(plugin),
         {:ok, mappings} <- fetch_mappings(plugin),
         :ok <- verify_mapping_signatures(plugin, mappings, opts) do
      case build_action_registry(mappings) do
        {:ok, actions} ->
          {:ok, %{plugin: plugin, action_mappings: mappings, actions: actions}}

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

  defp ensure_official_plugin(plugin), do: {:error, :untrusted_action_mapping_plugin, plugin}

  defp fetch_mappings(%{capability_manifest: %{"action_mappings" => mappings}} = plugin)
       when is_list(mappings) do
    if Enum.all?(mappings, &valid_mapping_shape?/1) do
      {:ok, mappings}
    else
      {:error, :invalid_action_mapping_manifest, plugin}
    end
  end

  defp fetch_mappings(%{capability_manifest: manifest} = plugin) when is_map(manifest) do
    case Map.get(manifest, "action_mappings", []) do
      [] -> {:ok, []}
      _other -> {:error, :invalid_action_mapping_manifest, plugin}
    end
  end

  defp verify_mapping_signatures(plugin, mappings, opts) do
    case MappingSignatureVerifier.verify_all(:action, plugin, mappings, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, plugin}
    end
  end

  defp valid_mapping_shape?(%{"key" => key, "module" => module_name})
       when is_binary(key) and is_binary(module_name) do
    true
  end

  defp valid_mapping_shape?(_mapping), do: false

  defp build_action_registry(mappings) do
    Enum.reduce_while(mappings, {:ok, %{}}, fn mapping, {:ok, actions} ->
      with {:ok, key} <- parse_action_key(mapping["key"]),
           {:ok, module} <- parse_action_module(mapping["module"]) do
        {:cont, {:ok, Map.put(actions, key, module)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_action_key(key) do
    case Map.fetch(@action_keys, key) do
      {:ok, action_key} -> {:ok, action_key}
      :error -> {:error, :invalid_action_mapping_key}
    end
  end

  defp parse_action_module(module_name) do
    module_name
    |> normalize_module_name()
    |> existing_module()
    |> case do
      {:ok, module} ->
        if function_exported?(module, :execute, 2) do
          {:ok, module}
        else
          {:error, :invalid_action_mapping_module}
        end

      :error ->
        {:error, :invalid_action_mapping_module}
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
