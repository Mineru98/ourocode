defmodule Ourocode.Command.Registry do
  @moduledoc """
  Normalized command registry for the terminal input layer.

  The first baseline starts with builtin slash commands. Registry sources can
  merge bundled, local, plugin, MCP, and dynamic skill commands into the same
  entry shape without changing the terminal prompt loop boundary.
  """

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.ConfigSchema.PluginEntry
  alias Ourocode.Command.Registry.Builtin
  alias Ourocode.Command.Registry.ContextualActions
  alias Ourocode.Command.Registry.DynamicSkill
  alias Ourocode.Command.Registry.Merge
  alias Ourocode.Command.Registry.McpToolLoader
  alias Ourocode.Command.Registry.PluginSurface
  alias Ourocode.Command.Registry.Query
  alias Ourocode.Command.Registry.Sources
  alias Ourocode.Command.Registry.SkillLoader

  @type source :: :builtin | :bundled_skill | :local | :plugin | :mcp | :dynamic_skill
  @type transport :: :stdio | :sse | :streamable_http | String.t()
  @type command_name :: String.t()
  @type slash_command :: String.t()
  @type command_id :: String.t()
  @type duplicate_reason :: :slash_collision | :alias_collision | :id_collision
  @type query_filter ::
          {:source, source()}
          | {:sources, [source()]}
          | {:category, atom()}
          | {:categories, [atom()]}
          | {:availability, :available | :stub}
          | {:runnable?, boolean()}
          | {:transport, transport()}
          | {:transports, [transport()]}
          | {:plugin_id, String.t()}
          | {:plugin_ids, [String.t()]}
          | {:source_id, String.t()}
          | {:source_ids, [String.t()]}
          | {:type, atom()}
          | {:types, [atom()]}
          | {:prefix, String.t()}
          | {:query, String.t()}
          | {:text, String.t()}
          | {:limit, pos_integer()}

  @type duplicate_record :: %{
          required(:reason) => duplicate_reason(),
          required(:source) => source(),
          required(:loser) => command_entry(),
          required(:winner) => command_entry(),
          required(:token) => slash_command()
        }

  @type argument :: %{
          required(:name) => String.t(),
          required(:required?) => boolean(),
          optional(:description) => String.t()
        }

  @type command_entry :: %{
          required(:id) => command_id(),
          required(:name) => command_name(),
          required(:slash) => slash_command(),
          required(:source) => source(),
          required(:source_id) => String.t(),
          required(:source_attribution) => map(),
          required(:type) => :slash_command,
          required(:category) => atom(),
          required(:summary) => String.t(),
          required(:aliases) => [slash_command()],
          required(:args) => [argument()],
          required(:availability) => :available | :stub,
          required(:runnable?) => boolean(),
          required(:run_spec) => map(),
          required(:metadata) => map()
        }

  @type t :: %{
          required(:status) => :ready,
          required(:sources) => [source()],
          required(:entries) => %{optional(slash_command()) => command_entry()},
          required(:aliases) => %{optional(slash_command()) => slash_command()},
          required(:ordered) => [command_entry()],
          required(:loaded_count) => non_neg_integer(),
          optional(:duplicates) => [duplicate_record()],
          optional(:duplicate_count) => non_neg_integer()
        }

  @type query_result :: [command_entry()]

  @doc """
  Loads the builtin ourocode command set into the normalized registry shape.
  """
  @spec load_builtin() :: {:ok, t()}
  def load_builtin do
    ordered = builtin_entries()

    entries = Map.new(ordered, fn entry -> {entry.slash, entry} end)

    aliases =
      ordered
      |> Enum.flat_map(fn entry -> Enum.map(entry.aliases, &{&1, entry.slash}) end)
      |> Map.new()

    {:ok,
     %{
       status: :ready,
       sources: [:builtin],
       entries: entries,
       aliases: aliases,
       ordered: ordered,
       loaded_count: length(ordered),
       duplicates: [],
       duplicate_count: 0
     }}
  end

  @doc """
  Loads the merged command registry.

  Bundled and local skills are discovered from directories passed as
  `:bundled_skill_dirs` and `:skill_dirs`. Each immediate child directory with a
  `SKILL.md` file is normalized into the same command entry shape as slash
  commands, with builtin commands taking precedence on slash collisions.
  """
  @spec load(keyword()) :: {:ok, t()}
  def load(opts \\ []) when is_list(opts) do
    {:ok, builtin_registry} = load_builtin()

    Sources.load(opts, builtin_registry)
  end

  @doc """
  Merges already-normalized slash command and skill entries into a registry.

  This is the shared boundary for command discovery surfaces that have already
  been adapted into `command_entry/0` maps. Entries are resolved in deterministic
  registry order, independent of caller input order, and existing registry
  entries keep precedence on slash or alias collisions.
  """
  @spec merge_normalized_entries(t(), command_entry() | [command_entry()] | nil) :: {:ok, t()}
  def merge_normalized_entries(registry, nil), do: merge_entries([], registry)

  def merge_normalized_entries(registry, entries) when is_list(entries) do
    entries
    |> Enum.filter(&is_map/1)
    |> merge_entries(registry)
  end

  def merge_normalized_entries(registry, entry) when is_map(entry) do
    merge_normalized_entries(registry, [entry])
  end

  @doc """
  Returns normalized builtin command entries in display order.
  """
  @spec builtin_entries() :: [command_entry()]
  def builtin_entries do
    Builtin.entries()
  end

  @doc """
  Looks up a canonical slash command or alias in a registry.
  """
  @spec fetch(t(), slash_command()) :: {:ok, command_entry()} | :error
  def fetch(%{entries: entries, aliases: aliases}, slash) when is_binary(slash) do
    canonical = Map.get(aliases, normalize_slash(slash), normalize_slash(slash))

    case Map.fetch(entries, canonical) do
      {:ok, entry} -> {:ok, entry}
      :error -> :error
    end
  end

  @doc """
  Returns registry entries in terminal display order.

  This is the read-only retrieval surface used by command palettes and
  discovery panes; callers should prefer it over reading the registry map
  internals directly.
  """
  @spec entries(t()) :: [command_entry()]
  def entries(%{ordered: ordered}) when is_list(ordered), do: ordered

  @doc """
  Queries the merged command registry while preserving display order.

  Supported filters include source/category/availability/runnable/type,
  transport, plugin/source id, slash prefix, free-text query, and limit. Text
  queries match command names, slashes, aliases, summaries, source metadata,
  argument names/descriptions, and tool/plugin identifiers.
  """
  @spec query(t(), [query_filter()]) :: query_result()
  def query(registry, filters \\ []) when is_map(registry) and is_list(filters) do
    Query.run(registry, filters)
  end

  @doc """
  Alias for `query/2` for callers that read more naturally as list APIs.
  """
  @spec list(t(), [query_filter()]) :: query_result()
  def list(registry, filters \\ []), do: query(registry, filters)

  @doc """
  Resolves a token and reports whether it matched the canonical slash or alias.
  """
  @spec resolve(t(), slash_command()) ::
          {:ok,
           %{
             required(:entry) => command_entry(),
             required(:token) => slash_command(),
             required(:canonical) => slash_command(),
             required(:match) => :canonical | :alias
           }}
          | :error
  def resolve(%{entries: entries, aliases: aliases}, token) when is_binary(token) do
    normalized = normalize_slash(token)
    canonical = Map.get(aliases, normalized, normalized)

    with {:ok, entry} <- Map.fetch(entries, canonical) do
      {:ok,
       %{
         entry: entry,
         token: normalized,
         canonical: canonical,
         match: if(normalized == canonical, do: :canonical, else: :alias)
       }}
    end
  end

  @doc """
  Returns normalized command entries for local skills under the given roots.
  """
  @spec local_skill_entries([Path.t()] | Path.t()) :: [command_entry()]
  def local_skill_entries(skill_dirs)

  def local_skill_entries(skill_dir) when is_binary(skill_dir),
    do: local_skill_entries([skill_dir])

  def local_skill_entries(skill_dirs) when is_list(skill_dirs) do
    SkillLoader.entries(skill_dirs, :local)
  end

  @doc """
  Returns normalized command entries for bundled skills under the given roots.
  """
  @spec bundled_skill_entries([Path.t()] | Path.t()) :: [command_entry()]
  def bundled_skill_entries(skill_dirs)

  def bundled_skill_entries(skill_dir) when is_binary(skill_dir),
    do: bundled_skill_entries([skill_dir])

  def bundled_skill_entries(skill_dirs) when is_list(skill_dirs) do
    SkillLoader.entries(skill_dirs, :bundled_skill)
  end

  @doc """
  Returns normalized command entries for enabled configured plugins.

  Official `ouroboros-plugin` config can expose default command and skill
  surfaces by setting `"commands": true` and/or `"skills": true`. Plugins can
  also provide explicit `"commands"` or `"skills"` lists in their preserved
  config map; both are normalized into the shared command surface.
  """
  @spec plugin_entries(ConfigSchema.t() | [PluginEntry.t()] | nil) :: [command_entry()]
  def plugin_entries(nil), do: []

  def plugin_entries(config_or_plugins), do: PluginSurface.entries(config_or_plugins)

  @doc """
  Returns normalized command entries for MCP tools discovered by transports.

  Accepts a plain `tools/list` result map, a list of tool maps, or transport
  envelopes carrying `:transport`, `:source_id`/`:server_id`, and `:tools` or
  `:entries`. Each accepted tool becomes a runnable slash command whose
  `run_spec` retains the original MCP tool name and transport metadata.
  """
  @spec mcp_entries(term()) :: [command_entry()]
  def mcp_entries(entries), do: McpToolLoader.entries(entries)

  @doc """
  Adds dynamically discovered skills to an already-loaded session registry.

  Dynamic skills are normalized into the same command surface as builtin,
  bundled, local, plugin, and MCP entries. Existing entries keep precedence on
  slash or alias collisions so session-time discovery cannot replace a loaded
  command.
  """
  @spec add_dynamic_skills(t(), map() | [map()] | nil) :: {:ok, t()}
  def add_dynamic_skills(registry, nil), do: merge_entries([], registry)

  def add_dynamic_skills(registry, skills) when is_list(skills) do
    skills
    |> Enum.filter(&is_map/1)
    |> Enum.map(&DynamicSkill.normalize!/1)
    |> merge_entries(registry)
  end

  def add_dynamic_skills(registry, %{} = skill) do
    add_dynamic_skills(registry, [skill])
  end

  @doc """
  Adds one dynamically discovered skill to an already-loaded session registry.
  """
  @spec add_dynamic_skill(t(), map()) :: {:ok, t()}
  def add_dynamic_skill(registry, %{} = skill), do: add_dynamic_skills(registry, skill)

  @doc """
  Projects a command registry for the current terminal focus context.

  Child session actions are intentionally contextual: they are exposed only when
  the runtime focus state resolves to one concrete child session. Aggregate
  child panes and parent/status/queue panes do not receive these actions.
  """
  @spec expose_contextual_actions(t(), keyword() | map()) :: {:ok, t()}
  def expose_contextual_actions(registry, context \\ []) when is_map(registry) do
    context
    |> ContextualActions.entries()
    |> merge_contextual_entries(registry)
  end

  defp merge_entries(new_entries, registry), do: Merge.run(new_entries, registry)

  defp merge_contextual_entries([], registry), do: {:ok, registry}

  defp merge_contextual_entries(new_entries, registry) do
    slashes = MapSet.new(new_entries, & &1.slash)
    aliases = MapSet.new(Enum.flat_map(new_entries, & &1.aliases))

    registry =
      registry
      |> Map.update!(:ordered, &Enum.reject(&1, fn entry -> entry.slash in slashes end))
      |> Map.update!(:entries, &Map.drop(&1, MapSet.to_list(slashes)))
      |> Map.update!(:aliases, &drop_contextual_aliases(&1, aliases, slashes))

    merge_entries(new_entries, registry)
  end

  defp drop_contextual_aliases(alias_map, aliases, slashes) do
    alias_map
    |> Enum.reject(fn {alias, slash} -> alias in aliases or slash in slashes end)
    |> Map.new()
  end

  defp normalize_slash(command) when is_binary(command) do
    command = String.trim(command)

    if String.starts_with?(command, "/") do
      command
    else
      "/#{command}"
    end
  end
end
