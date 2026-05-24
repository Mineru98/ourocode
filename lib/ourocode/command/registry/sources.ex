defmodule Ourocode.Command.Registry.Sources do
  @moduledoc false

  alias Ourocode.Command.Registry.McpToolLoader
  alias Ourocode.Command.Registry.Merge
  alias Ourocode.Command.Registry.PluginSurface
  alias Ourocode.Command.Registry.SkillLoader

  @spec load(keyword(), map()) :: {:ok, map()}
  def load(opts, builtin_registry) when is_list(opts) and is_map(builtin_registry) do
    with {:ok, registry} <-
           opts
           |> bundled_skill_dirs()
           |> SkillLoader.entries(:bundled_skill)
           |> Merge.run(builtin_registry),
         {:ok, registry} <-
           opts
           |> skill_dirs()
           |> SkillLoader.entries(:local)
           |> Merge.run(registry),
         {:ok, registry} <-
           opts
           |> plugin_config()
           |> PluginSurface.entries()
           |> Merge.run(registry) do
      opts
      |> mcp_entries()
      |> McpToolLoader.entries()
      |> Merge.run(registry)
    end
  end

  @spec skill_dirs(keyword()) :: [Path.t()]
  def skill_dirs(opts) do
    Keyword.get(opts, :skill_dirs, default_skill_dirs())
  end

  @spec bundled_skill_dirs(keyword()) :: [Path.t()]
  def bundled_skill_dirs(opts) do
    Keyword.get(opts, :bundled_skill_dirs, default_bundled_skill_dirs())
  end

  @spec plugin_config(keyword()) :: term()
  def plugin_config(opts) do
    Keyword.get_lazy(opts, :plugin_config, fn -> Keyword.get(opts, :plugins, []) end)
  end

  @spec mcp_entries(keyword()) :: term()
  def mcp_entries(opts) do
    Keyword.get(opts, :mcp_entries, [])
  end

  @spec default_skill_dirs() :: [Path.t()]
  def default_skill_dirs do
    case System.get_env("OUROCODE_SKILL_DIRS") do
      nil -> [Path.expand("~/.codex/skills")]
      "" -> []
      dirs -> String.split(dirs, path_separator(), trim: true)
    end
  end

  @spec default_bundled_skill_dirs() :: [Path.t()]
  def default_bundled_skill_dirs do
    source_priv = Path.expand("priv/skills", File.cwd!())

    case :code.priv_dir(:ourocode) do
      path when is_list(path) ->
        [Path.join(to_string(path), "skills"), source_priv]
        |> Enum.uniq()

      {:error, :bad_name} ->
        [source_priv]
    end
  end

  @spec path_separator() :: String.t()
  def path_separator do
    case :os.type() do
      {:win32, _name} -> ";"
      _other -> ":"
    end
  end
end
