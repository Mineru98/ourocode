defmodule Ourocode.Command.Registry do
  @moduledoc """
  Normalized command registry for the terminal input layer.

  The first baseline starts with builtin slash commands. Registry sources can
  merge bundled, local, plugin, MCP, and dynamic skill commands into the same
  entry shape without changing the terminal prompt loop boundary.
  """

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.ConfigSchema.PluginEntry
  alias Ourocode.Command.RegistryEntryAdapter
  alias Ourocode.Runtime.FocusState

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

  @builtin_definitions [
    %{
      name: "help",
      slash: "/help",
      aliases: ["/?"],
      category: :discovery,
      summary: "Show available commands and skills.",
      run_spec: %{kind: :builtin_action, action: :show_help}
    },
    %{
      name: "commands",
      slash: "/commands",
      aliases: ["/cmds"],
      category: :discovery,
      summary: "Open the merged command registry view.",
      run_spec: %{kind: :builtin_action, action: :show_commands}
    },
    %{
      name: "skills",
      slash: "/skills",
      aliases: [],
      category: :discovery,
      summary: "Open skill discovery from the merged registry.",
      run_spec: %{kind: :builtin_action, action: :show_skills}
    },
    %{
      name: "capabilities",
      slash: "/capabilities",
      aliases: ["/caps"],
      category: :discovery,
      summary: "Show the merged runtime capability graph.",
      run_spec: %{kind: :builtin_action, action: :show_capabilities}
    },
    %{
      name: "clear",
      slash: "/clear",
      aliases: [],
      category: :runtime,
      summary:
        "Clear the current terminal screen and prompt buffer without deleting journal history.",
      run_spec: %{kind: :builtin_action, action: :clear_screen}
    },
    %{
      name: "resume",
      slash: "/resume",
      aliases: [],
      category: :journal,
      summary: "List previous journaled sessions and reconnect to one.",
      args: [
        %{
          name: "session",
          required?: false,
          description: "Optional session or journal id to resume"
        }
      ],
      run_spec: %{kind: :builtin_action, action: :resume_session}
    },
    %{
      name: "exit",
      slash: "/exit",
      aliases: [],
      category: :runtime,
      summary: "Exit the terminal UI cleanly.",
      run_spec: %{kind: :builtin_action, action: :exit}
    },
    %{
      name: "quit",
      slash: "/quit",
      aliases: [],
      category: :runtime,
      summary: "Exit the terminal UI cleanly.",
      run_spec: %{kind: :builtin_action, action: :exit}
    },
    %{
      name: "status",
      slash: "/status",
      aliases: ["/health"],
      category: :runtime,
      summary: "Show runtime, transport, plugin, hook, and queue health.",
      run_spec: %{kind: :builtin_action, action: :show_status}
    },
    %{
      name: "pane",
      slash: "/pane",
      aliases: ["/focus"],
      category: :steering,
      summary: "Focus or open a terminal pane.",
      args: [%{name: "pane_id", required?: true, description: "Pane id or child session id"}],
      run_spec: %{kind: :builtin_action, action: :focus_pane}
    },
    %{
      name: "children",
      slash: "/children",
      aliases: ["/child"],
      category: :steering,
      summary: "Show child session panes and steering targets.",
      run_spec: %{kind: :builtin_action, action: :show_children}
    },
    %{
      name: "queue",
      slash: "/queue",
      aliases: ["/notifications"],
      category: :visibility,
      summary: "Show queued notifications and overflow summaries.",
      run_spec: %{kind: :builtin_action, action: :show_queue}
    },
    %{
      name: "hooks",
      slash: "/hooks",
      aliases: [],
      category: :visibility,
      summary: "Show hook lifecycle activity.",
      run_spec: %{kind: :builtin_action, action: :show_hooks}
    },
    %{
      name: "wonder",
      slash: "/wonder",
      aliases: ["/wonderTool"],
      category: :interaction,
      summary: "Show active wonderTool interaction flows.",
      run_spec: %{kind: :builtin_action, action: :show_wonder_tool}
    },
    %{
      name: "plugins",
      slash: "/plugins",
      aliases: [],
      category: :plugins,
      summary: "Show configured official and third-party plugins.",
      run_spec: %{kind: :builtin_action, action: :show_plugins}
    },
    %{
      name: "mcp",
      slash: "/mcp",
      aliases: [],
      category: :runtime,
      availability: :stub,
      summary: "Show stdio, SSE, and streamable HTTP MCP transport status.",
      run_spec: %{kind: :builtin_action, action: :show_mcp}
    },
    %{
      name: "sessions",
      slash: "/sessions",
      aliases: [],
      category: :steering,
      availability: :stub,
      summary: "Show the parent and child session list.",
      run_spec: %{kind: :builtin_action, action: :show_sessions}
    },
    %{
      name: "config",
      slash: "/config",
      aliases: [],
      category: :plugins,
      availability: :stub,
      summary: "Show plugin/runtime config and reload guidance.",
      run_spec: %{kind: :builtin_action, action: :show_config}
    },
    %{
      name: "model",
      slash: "/model",
      aliases: ["/models"],
      category: :runtime,
      summary: "Pick the active main-session backend (detected models).",
      run_spec: %{kind: :builtin_action, action: :select_model}
    },
    %{
      name: "login",
      slash: "/login",
      aliases: ["/signin"],
      category: :runtime,
      summary: "Connect the main session to ChatGPT via Codex OAuth.",
      run_spec: %{kind: :builtin_action, action: :provider_login}
    },
    %{
      name: "logout",
      slash: "/logout",
      aliases: ["/signout"],
      category: :runtime,
      summary: "Disconnect the current model provider.",
      run_spec: %{kind: :builtin_action, action: :provider_logout}
    },
    %{
      name: "reload",
      slash: "/reload",
      aliases: [],
      category: :plugins,
      summary: "Reload plugin and command registries at the Elixir boundary.",
      run_spec: %{kind: :builtin_action, action: :reload_runtime_boundary}
    },
    %{
      name: "replay",
      slash: "/replay",
      aliases: [],
      category: :journal,
      summary: "Replay journaled terminal-visible state.",
      run_spec: %{kind: :builtin_action, action: :replay_journal}
    }
  ]

  @official_ouroboros_plugin_id "ouroboros-plugin"
  @official_ouroboros_namespace "plugin:official:ouroboros"

  @official_ouroboros_commands [
    %{
      "name" => "ooo",
      "slash" => "/ooo",
      "aliases" => ["/ouroboros"],
      "description" => "Run the official Ouroboros workflow surface.",
      "action" => "workflow",
      "args" => [
        %{
          "name" => "goal",
          "required" => false,
          "description" => "Natural-language workflow goal"
        }
      ]
    },
    %{
      "name" => "interview",
      "slash" => "/interview",
      "description" => "Start an official Ouroboros clarification interview.",
      "action" => "interview"
    },
    %{
      "name" => "seed",
      "slash" => "/seed",
      "description" => "Generate an official Ouroboros Seed from an interview.",
      "action" => "seed"
    },
    %{
      "name" => "evolve",
      "slash" => "/evolve",
      "description" => "Run one official Ouroboros evolution step.",
      "action" => "evolve"
    },
    %{
      "name" => "ralph",
      "slash" => "/ralph",
      "description" => "Start the official Ouroboros Ralph convergence loop.",
      "action" => "ralph"
    }
  ]

  @official_ouroboros_skills [
    %{
      "name" => "ouroboros-qa",
      "slash" => "/ouroboros-qa",
      "description" => "Evaluate an artifact with the official Ouroboros QA flow.",
      "mcp_tool" => "ouroboros_qa"
    },
    %{
      "name" => "ouroboros-clarify",
      "slash" => "/ouroboros-clarify",
      "description" =>
        "Clarify vague requirements through the official Ouroboros interview flow.",
      "mcp_tool" => "ouroboros_interview"
    }
  ]

  @official_reserved_slashes MapSet.new(
                               Enum.flat_map(
                                 @official_ouroboros_commands ++ @official_ouroboros_skills,
                                 fn definition ->
                                   [definition["slash"] | Map.get(definition, "aliases", [])]
                                 end
                               )
                             )

  @interrupt_definition %{
    name: "interrupt",
    slash: "/interrupt",
    aliases: ["/stop-child"],
    category: :steering,
    summary: "Interrupt the currently focused child session.",
    run_spec: %{kind: :builtin_action, action: :interrupt_focused_child}
  }

  @cancel_definition %{
    name: "cancel",
    slash: "/cancel",
    aliases: ["/cancel-child"],
    category: :steering,
    summary: "Cancel the currently focused child session.",
    args: [
      %{
        name: "reason",
        required?: false,
        description: "Optional cancellation reason sent to the child session"
      }
    ],
    run_spec: %{kind: :builtin_action, action: :cancel_focused_child}
  }

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

    {:ok, registry} =
      opts
      |> Keyword.get(:bundled_skill_dirs, default_bundled_skill_dirs())
      |> bundled_skill_entries()
      |> merge_entries(builtin_registry)

    {:ok, registry} =
      opts
      |> Keyword.get(:skill_dirs, default_skill_dirs())
      |> local_skill_entries()
      |> merge_entries(registry)

    opts
    |> plugin_config_from_opts()
    |> plugin_entries()
    |> merge_entries(registry)
    |> then(fn {:ok, registry} ->
      opts
      |> Keyword.get(:mcp_entries, [])
      |> mcp_entries()
      |> merge_entries(registry)
    end)
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
    Enum.map(@builtin_definitions, &normalize_builtin!/1)
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
    filters = normalize_query_filters(filters)

    registry
    |> entries()
    |> Enum.filter(&query_match?(&1, filters))
    |> maybe_limit(filters)
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
    skill_dirs
    |> Enum.flat_map(&discover_skill_files/1)
    |> Enum.map(&normalize_local_skill!/1)
    |> Enum.sort_by(& &1.slash)
  end

  @doc """
  Returns normalized command entries for bundled skills under the given roots.
  """
  @spec bundled_skill_entries([Path.t()] | Path.t()) :: [command_entry()]
  def bundled_skill_entries(skill_dirs)

  def bundled_skill_entries(skill_dir) when is_binary(skill_dir),
    do: bundled_skill_entries([skill_dir])

  def bundled_skill_entries(skill_dirs) when is_list(skill_dirs) do
    skill_dirs
    |> Enum.flat_map(&discover_skill_files/1)
    |> Enum.map(&normalize_bundled_skill!/1)
    |> Enum.sort_by(& &1.slash)
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

  def plugin_entries(%ConfigSchema{plugins: plugins}), do: plugin_entries(plugins)

  def plugin_entries(plugins) when is_list(plugins) do
    plugins
    |> Enum.flat_map(&normalize_plugin_entries/1)
    |> Enum.sort_by(& &1.slash)
  end

  @doc """
  Returns normalized command entries for MCP tools discovered by transports.

  Accepts a plain `tools/list` result map, a list of tool maps, or transport
  envelopes carrying `:transport`, `:source_id`/`:server_id`, and `:tools` or
  `:entries`. Each accepted tool becomes a runnable slash command whose
  `run_spec` retains the original MCP tool name and transport metadata.
  """
  @spec mcp_entries(term()) :: [command_entry()]
  def mcp_entries(nil), do: []

  def mcp_entries(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(&mcp_entries/1)
    |> Enum.sort_by(& &1.slash)
  end

  def mcp_entries(%{} = envelope) do
    cond do
      tools = mcp_tool_list(envelope) ->
        context = mcp_envelope_context(envelope)

        tools
        |> Enum.filter(&mcp_user_invocable?/1)
        |> Enum.map(&normalize_mcp_tool!(&1, context))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.slash)

      mcp_tool_entry?(envelope) and mcp_user_invocable?(envelope) ->
        envelope
        |> normalize_mcp_tool!(mcp_envelope_context(envelope))
        |> List.wrap()

      true ->
        []
    end
  end

  def mcp_entries(_entries), do: []

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
    |> Enum.map(&normalize_dynamic_skill!/1)
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
    context = Map.new(context)
    focus_state = Map.get(context, :focus_state, FocusState.new())
    pane_model = Map.get(context, :pane_model, %{})

    case FocusState.focused_child_session(focus_state, pane_model) do
      {:ok, focused_child} ->
        [
          child_action_entry(@interrupt_definition, focused_child,
            introduced_in: :interrupt_baseline,
            requires_metadata_key: :requires_focused_child_session?
          ),
          child_action_entry(@cancel_definition, focused_child,
            introduced_in: :cancel_baseline,
            requires_metadata_key: :requires_focused_child_session?
          )
        ]
        |> merge_entries(registry)

      {:error, _reason} ->
        {:ok, registry}
    end
  end

  defp normalize_builtin!(definition) do
    slash = definition |> Map.fetch!(:slash) |> normalize_slash()

    RegistryEntryAdapter.from_slash_command!(definition,
      id: "builtin:#{slash}",
      source: :builtin,
      source_id: "builtin",
      distribution: :builtin,
      category: Map.fetch!(definition, :category),
      run_spec: Map.fetch!(definition, :run_spec),
      availability: Map.get(definition, :availability, :available),
      metadata: %{introduced_in: :interactive_baseline},
      source_attribution: %{
        source: :builtin,
        source_id: "builtin",
        distribution: :builtin
      }
    )
  end

  defp child_action_entry(definition, focused_child, options) do
    requires_metadata_key = Keyword.fetch!(options, :requires_metadata_key)

    definition
    |> normalize_builtin!()
    |> put_in([:source_attribution, requires_metadata_key], true)
    |> put_in([:run_spec, :target], :focused_child_session)
    |> put_in([:run_spec, :child_session_id], focused_child.session_id)
    |> put_in([:run_spec, :child_pane_id], focused_child.pane_id)
    |> put_in([:metadata, :introduced_in], Keyword.fetch!(options, :introduced_in))
    |> put_in([:metadata, :contextual?], true)
    |> put_in([:metadata, requires_metadata_key], true)
    |> put_in([:metadata, :focused_child_session], %{
      pane_id: focused_child.pane_id,
      session_id: focused_child.session_id,
      child_id: focused_child.child_id,
      kind: focused_child.kind
    })
  end

  defp normalize_local_skill!(skill_file) do
    normalize_skill!(skill_file, :local)
  end

  defp normalize_bundled_skill!(skill_file) do
    normalize_skill!(skill_file, :bundled_skill)
  end

  defp normalize_plugin_entries(%PluginEntry{enabled: false}), do: []

  defp normalize_plugin_entries(%PluginEntry{} = plugin) do
    commands = plugin_surface_definitions(plugin, "commands", @official_ouroboros_commands)
    skills = plugin_surface_definitions(plugin, "skills", @official_ouroboros_skills)

    command_entries =
      Enum.map(commands, fn definition ->
        normalize_plugin_surface!(plugin, definition, :command)
      end)

    skill_entries =
      Enum.map(skills, fn definition -> normalize_plugin_surface!(plugin, definition, :skill) end)

    command_entries
    |> Kernel.++(skill_entries)
    |> Enum.reject(&reserved_official_namespace_violation?/1)
  end

  defp normalize_plugin_entries(_plugin), do: []

  defp normalize_mcp_tool!(tool, context) do
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

      aliases =
        tool
        |> field("aliases", [])
        |> List.wrap()
        |> Enum.map(&normalize_slash(to_string(&1)))

      args =
        tool
        |> mcp_tool_args()
        |> Enum.map(&normalize_mcp_arg!/1)

      transport = Map.fetch!(context, :transport)
      source_id = Map.fetch!(context, :source_id)

      source_attribution = %{
        source: :mcp,
        source_id: source_id,
        transport: transport,
        server_id: source_id,
        discovered_from: Map.get(context, :discovered_from)
      }

      invocability = mcp_invocability_metadata(tool)

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
        aliases: aliases,
        args: args,
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

  defp normalize_dynamic_skill!(definition) when is_map(definition) do
    name =
      definition
      |> field("name", field(definition, "id", "dynamic-skill"))
      |> to_string()
      |> slugify_name()

    source_id =
      definition
      |> field("source_id", field(definition, "session_id", "session"))
      |> to_string()

    discovered_from =
      definition
      |> field("discovered_from", "session")
      |> to_string()

    mcp_tool = field(definition, "mcp_tool", nil)

    source_attribution = %{
      source: :dynamic_skill,
      source_id: source_id,
      distribution: :dynamic,
      discovered_from: discovered_from
    }

    RegistryEntryAdapter.from_skill_definition!(definition,
      id: "dynamic_skill:#{source_id}:#{name}",
      source: :dynamic_skill,
      source_id: source_id,
      source_attribution: source_attribution,
      distribution: :dynamic,
      run_kind: :dynamic_skill,
      run_spec:
        %{
          kind: :dynamic_skill,
          skill_id: field(definition, "id", name) |> to_string(),
          discovered_from: discovered_from
        }
        |> maybe_put(:mcp_tool, mcp_tool),
      metadata: %{
        distribution: :dynamic,
        discovered_from: discovered_from,
        source_attribution: source_attribution
      }
    )
  end

  defp normalize_plugin_surface!(%PluginEntry{} = plugin, definition, surface) do
    name =
      definition
      |> field("name", field(definition, :name, ""))
      |> unquote_scalar()
      |> slugify_name()

    slash =
      definition
      |> field("slash", name)
      |> normalize_slash()

    aliases =
      definition
      |> field("aliases", [])
      |> List.wrap()
      |> Enum.map(&normalize_slash(to_string(&1)))

    args =
      definition
      |> field("args", [])
      |> List.wrap()
      |> Enum.map(&normalize_plugin_arg!/1)

    summary =
      definition
      |> field("description", field(definition, "summary", ""))
      |> to_string()

    run_kind = if surface == :skill, do: :plugin_skill, else: :plugin_command
    mcp_tool = field(definition, "mcp_tool", nil)
    action = field(definition, "action", name)

    run_spec =
      %{
        kind: run_kind,
        plugin_id: plugin.id,
        plugin_path: plugin.path,
        action: action
      }
      |> maybe_put(:mcp_tool, mcp_tool)

    command_namespace = plugin_command_namespace(plugin)
    namespace_owner = plugin_namespace_owner(plugin)

    source_attribution =
      plugin_source_attribution(plugin, surface, command_namespace, namespace_owner)

    %{
      id: "plugin:#{plugin.id}:#{name}",
      name: name,
      slash: slash,
      source: :plugin,
      source_id: plugin.id,
      source_attribution: source_attribution,
      type: :slash_command,
      category: if(surface == :skill, do: :skills, else: :plugins),
      summary: summary,
      aliases: aliases,
      args: args,
      availability: :available,
      runnable?: true,
      run_spec: run_spec,
      metadata: %{
        plugin_id: plugin.id,
        plugin_source: plugin.source,
        plugin_surface: surface,
        command_namespace: command_namespace,
        namespace_owner: namespace_owner,
        loaded_from: plugin.path,
        provenance: plugin.provenance,
        trust_policy: plugin.trust_policy,
        trust_evaluation: plugin.trust_evaluation,
        package_identity: ConfigSchema.to_map(plugin)["package_identity"],
        source_attribution: source_attribution
      }
    }
  end

  defp normalize_skill!(%{root: root, dir: skill_dir, file: skill_file}, source) do
    metadata = skill_file |> File.read!() |> parse_skill_frontmatter()

    name =
      metadata |> Map.get("name", Path.basename(skill_dir)) |> unquote_scalar() |> slugify_name()

    slash = normalize_slash(name)
    description = metadata |> Map.get("description", "") |> unquote_scalar()
    mcp_tool = metadata |> Map.get("mcp_tool") |> maybe_unquote_scalar()

    run_kind = skill_run_kind(source)
    source_id = Path.expand(root)

    source_attribution = %{
      source: source,
      source_id: source_id,
      distribution: skill_distribution(source),
      skill_path: skill_dir,
      skill_file: skill_file
    }

    run_spec =
      %{
        kind: run_kind,
        skill_path: skill_dir,
        skill_file: skill_file
      }
      |> maybe_put(:mcp_tool, mcp_tool)

    RegistryEntryAdapter.from_skill_definition!(
      %{
        name: name,
        slash: slash,
        description: description,
        mcp_tool: mcp_tool
      },
      id: "#{run_kind}:#{name}",
      source: source,
      source_id: source_id,
      source_attribution: source_attribution,
      distribution: skill_distribution(source),
      run_kind: run_kind,
      run_spec: run_spec,
      metadata: %{
        skill_path: skill_dir,
        skill_file: skill_file,
        distribution: skill_distribution(source),
        frontmatter_keys: Map.keys(metadata) |> Enum.sort(),
        source_attribution: source_attribution
      }
    )
  end

  defp merge_entries(new_entries, registry) do
    {accepted_entries, duplicate_records} =
      new_entries
      |> Enum.sort_by(&command_resolution_key/1)
      |> Enum.reduce({[], []}, fn entry, {accepted, duplicates} ->
        lookup = command_lookup(registry, accepted)

        case duplicate_record(entry, lookup) do
          nil ->
            {accepted ++ [entry], duplicates}

          duplicate ->
            {accepted, duplicates ++ [duplicate]}
        end
      end)

    ordered = registry.ordered ++ accepted_entries

    entries =
      Map.merge(registry.entries, Map.new(accepted_entries, fn entry -> {entry.slash, entry} end))

    aliases =
      accepted_entries
      |> Enum.flat_map(fn entry -> Enum.map(entry.aliases, &{&1, entry.slash}) end)
      |> Map.new()
      |> then(&Map.merge(registry.aliases, &1))

    sources = Enum.uniq(registry.sources ++ Enum.map(accepted_entries, & &1.source))

    {:ok,
     %{
       registry
       | sources: sources,
         entries: entries,
         aliases: aliases,
         ordered: ordered,
         loaded_count: length(ordered),
         duplicates: Map.get(registry, :duplicates, []) ++ duplicate_records,
         duplicate_count: Map.get(registry, :duplicate_count, 0) + length(duplicate_records)
     }}
  end

  defp normalize_query_filters(filters) do
    filters
    |> Enum.flat_map(fn
      {:source, source} ->
        [{:sources, MapSet.new([source])}]

      {:sources, sources} ->
        [{:sources, sources |> List.wrap() |> MapSet.new()}]

      {:category, category} ->
        [{:categories, MapSet.new([category])}]

      {:categories, categories} ->
        [{:categories, categories |> List.wrap() |> MapSet.new()}]

      {:transport, transport} ->
        [{:transports, MapSet.new([normalize_transport(transport)])}]

      {:transports, transports} ->
        [
          {:transports,
           transports |> List.wrap() |> Enum.map(&normalize_transport/1) |> MapSet.new()}
        ]

      {:plugin_id, plugin_id} ->
        [{:plugin_ids, MapSet.new([to_string(plugin_id)])}]

      {:plugin_ids, plugin_ids} ->
        [{:plugin_ids, plugin_ids |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()}]

      {:source_id, source_id} ->
        [{:source_ids, MapSet.new([to_string(source_id)])}]

      {:source_ids, source_ids} ->
        [{:source_ids, source_ids |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()}]

      {:type, type} ->
        [{:types, MapSet.new([type])}]

      {:types, types} ->
        [{:types, types |> List.wrap() |> MapSet.new()}]

      {:prefix, prefix} ->
        [{:prefix, normalize_slash(to_string(prefix))}]

      {:query, query} ->
        [{:query, normalize_search_text(query)}]

      {:text, query} ->
        [{:query, normalize_search_text(query)}]

      {:availability, availability} ->
        [{:availability, availability}]

      {:runnable?, runnable?} when is_boolean(runnable?) ->
        [{:runnable?, runnable?}]

      {:limit, limit} when is_integer(limit) and limit > 0 ->
        [{:limit, limit}]

      _unknown ->
        []
    end)
  end

  defp query_match?(entry, filters) do
    Enum.all?(filters, fn
      {:sources, sources} -> MapSet.member?(sources, entry.source)
      {:categories, categories} -> MapSet.member?(categories, entry.category)
      {:availability, availability} -> entry.availability == availability
      {:runnable?, runnable?} -> entry.runnable? == runnable?
      {:transports, transports} -> MapSet.member?(transports, entry_transport(entry))
      {:plugin_ids, plugin_ids} -> MapSet.member?(plugin_ids, entry_plugin_id(entry))
      {:source_ids, source_ids} -> MapSet.member?(source_ids, to_string(entry.source_id))
      {:types, types} -> MapSet.member?(types, entry.type)
      {:prefix, prefix} -> entry_prefix_match?(entry, prefix)
      {:query, ""} -> true
      {:query, query} -> entry_search_match?(entry, query)
      {:limit, _limit} -> true
    end)
  end

  defp maybe_limit(entries, filters) do
    case Keyword.get(filters, :limit) do
      limit when is_integer(limit) and limit > 0 -> Enum.take(entries, limit)
      _none -> entries
    end
  end

  defp entry_transport(entry) do
    Map.get(entry.metadata, :transport) ||
      Map.get(entry.run_spec, :transport) ||
      Map.get(entry.source_attribution, :transport)
  end

  defp entry_plugin_id(entry) do
    plugin_id =
      Map.get(entry.metadata, :plugin_id) ||
        Map.get(entry.run_spec, :plugin_id) ||
        Map.get(entry.source_attribution, :plugin_id)

    if is_nil(plugin_id), do: nil, else: to_string(plugin_id)
  end

  defp entry_prefix_match?(entry, prefix) do
    Enum.any?([entry.slash | entry.aliases], &String.starts_with?(&1, prefix))
  end

  defp entry_search_match?(entry, query) do
    entry
    |> entry_search_values()
    |> Enum.any?(fn value ->
      value
      |> normalize_search_text()
      |> String.contains?(query)
    end)
  end

  defp entry_search_values(entry) do
    arg_values =
      entry.args
      |> Enum.flat_map(fn arg ->
        [arg.name, Map.get(arg, :description, "")]
      end)

    metadata_values = [
      Map.get(entry.metadata, :plugin_id),
      Map.get(entry.metadata, :plugin_source),
      Map.get(entry.metadata, :tool_name),
      Map.get(entry.metadata, :server_id),
      Map.get(entry.metadata, :transport),
      Map.get(entry.metadata, :discovered_from),
      Map.get(entry.metadata, :command_namespace)
    ]

    run_spec_values = [
      Map.get(entry.run_spec, :kind),
      Map.get(entry.run_spec, :action),
      Map.get(entry.run_spec, :mcp_tool),
      Map.get(entry.run_spec, :tool_name),
      Map.get(entry.run_spec, :plugin_id),
      Map.get(entry.run_spec, :server_id),
      Map.get(entry.run_spec, :transport)
    ]

    [
      entry.id,
      entry.name,
      entry.slash,
      entry.source,
      entry.source_id,
      entry.category,
      entry.summary
      | entry.aliases ++ arg_values ++ metadata_values ++ run_spec_values
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp normalize_search_text(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp command_resolution_key(entry) do
    {
      source_priority(entry.source),
      entry.slash,
      entry.source_id,
      get_in(entry, [:metadata, :skill_path]) || "",
      entry.id
    }
  end

  defp source_priority(:builtin), do: 0
  defp source_priority(:bundled_skill), do: 1
  defp source_priority(:local), do: 2
  defp source_priority(:plugin), do: 3
  defp source_priority(:mcp), do: 4
  defp source_priority(:dynamic_skill), do: 5

  defp command_lookup(registry, accepted_entries) do
    accepted_entry_map = Map.new(accepted_entries, fn entry -> {entry.slash, entry} end)
    accepted_id_map = Map.new(accepted_entries, fn entry -> {entry.id, entry} end)

    accepted_alias_map =
      accepted_entries
      |> Enum.flat_map(fn entry -> Enum.map(entry.aliases, &{&1, entry.slash}) end)
      |> Map.new()

    %{
      entries: Map.merge(registry.entries, accepted_entry_map),
      aliases: Map.merge(registry.aliases, accepted_alias_map),
      ids: Map.merge(command_id_lookup(registry), accepted_id_map)
    }
  end

  defp duplicate_record(entry, lookup) do
    cond do
      winner = Map.get(lookup.entries, entry.slash) ->
        duplicate_record(:slash_collision, entry.source, entry, winner, entry.slash)

      winner_slash = Map.get(lookup.aliases, entry.slash) ->
        duplicate_record(
          :slash_collision,
          entry.source,
          entry,
          Map.fetch!(lookup.entries, winner_slash),
          entry.slash
        )

      conflict = alias_conflict(entry.aliases, lookup) ->
        {token, winner} = conflict
        duplicate_record(:alias_collision, entry.source, entry, winner, token)

      winner = Map.get(lookup.ids, entry.id) ->
        duplicate_record(:id_collision, entry.source, entry, winner, entry.id)

      true ->
        nil
    end
  end

  defp command_id_lookup(registry) do
    registry.ordered
    |> Map.new(fn entry -> {entry.id, entry} end)
  end

  defp duplicate_record(reason, source, loser, winner, token) do
    %{
      reason: reason,
      source: source,
      loser: loser,
      winner: winner,
      token: token
    }
  end

  defp alias_conflict(aliases, lookup) do
    Enum.find_value(aliases, fn alias ->
      cond do
        winner = Map.get(lookup.entries, alias) ->
          {alias, winner}

        winner_slash = Map.get(lookup.aliases, alias) ->
          {alias, Map.fetch!(lookup.entries, winner_slash)}

        true ->
          nil
      end
    end)
  end

  defp discover_skill_files(skill_dir) do
    root = Path.expand(skill_dir)

    case File.ls(root) do
      {:ok, children} ->
        children
        |> Enum.sort()
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(fn child -> %{root: root, dir: child, file: Path.join(child, "SKILL.md")} end)
        |> Enum.filter(&File.regular?(&1.file))

      {:error, _reason} ->
        []
    end
  end

  defp parse_skill_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---", parts: 2) do
      [frontmatter, _body] -> parse_frontmatter_lines(frontmatter)
      [_without_closing_marker] -> %{}
    end
  end

  defp parse_skill_frontmatter(_contents), do: %{}

  defp parse_frontmatter_lines(frontmatter) do
    frontmatter
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, metadata ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          key = String.trim(key)

          if key == "" or String.starts_with?(key, "#") do
            metadata
          else
            Map.put(metadata, key, String.trim(value))
          end

        _other ->
          metadata
      end
    end)
  end

  defp default_skill_dirs do
    case System.get_env("OUROCODE_SKILL_DIRS") do
      nil -> [Path.expand("~/.codex/skills")]
      "" -> []
      dirs -> String.split(dirs, path_separator(), trim: true)
    end
  end

  defp default_bundled_skill_dirs do
    source_priv = Path.expand("priv/skills", File.cwd!())

    case :code.priv_dir(:ourocode) do
      path when is_list(path) ->
        [Path.join(to_string(path), "skills"), source_priv]
        |> Enum.uniq()

      {:error, :bad_name} ->
        [source_priv]
    end
  end

  defp path_separator do
    case :os.type() do
      {:win32, _name} -> ";"
      _other -> ":"
    end
  end

  defp normalize_slash(command) when is_binary(command) do
    command = String.trim(command)

    if String.starts_with?(command, "/") do
      command
    else
      "/#{command}"
    end
  end

  defp maybe_unquote_scalar(nil), do: nil
  defp maybe_unquote_scalar(value), do: unquote_scalar(value)

  defp unquote_scalar(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp slugify_name(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp skill_distribution(:bundled_skill), do: :bundled
  defp skill_distribution(:local), do: :local

  defp skill_run_kind(:bundled_skill), do: :bundled_skill
  defp skill_run_kind(:local), do: :local_skill

  defp plugin_source_attribution(
         %PluginEntry{} = plugin,
         surface,
         command_namespace,
         namespace_owner
       ) do
    source_metadata = ConfigSchema.source_metadata(plugin)

    %{
      source: :plugin,
      source_id: plugin.id,
      plugin_id: plugin.id,
      plugin_source: plugin.source,
      plugin_surface: surface,
      command_namespace: command_namespace,
      namespace_owner: namespace_owner,
      loaded_from: plugin.path,
      provenance: source_metadata["provenance"],
      trust_policy: source_metadata["trust_policy"],
      trust_evaluation: source_metadata["trust_evaluation"],
      package_identity: source_metadata["package_identity"]
    }
  end

  defp plugin_config_from_opts(opts) do
    Keyword.get_lazy(opts, :plugin_config, fn -> Keyword.get(opts, :plugins, []) end)
  end

  defp plugin_surface_definitions(%PluginEntry{} = plugin, key, official_defaults) do
    config = plugin.config || %{}

    case field(config, key, false) do
      true ->
        if official_ouroboros_plugin?(plugin), do: official_defaults, else: []

      definitions when is_list(definitions) ->
        definitions

      definitions when is_map(definitions) ->
        definitions
        |> Map.values()
        |> Enum.filter(&is_map/1)

      _disabled_or_invalid ->
        []
    end
  end

  defp official_ouroboros_plugin?(%PluginEntry{
         id: @official_ouroboros_plugin_id,
         source: "official"
       }) do
    true
  end

  defp official_ouroboros_plugin?(_plugin), do: false

  defp plugin_command_namespace(%PluginEntry{} = plugin) do
    if official_ouroboros_plugin?(plugin) do
      @official_ouroboros_namespace
    else
      "plugin:#{plugin.source}:#{plugin.id}"
    end
  end

  defp plugin_namespace_owner(%PluginEntry{} = plugin) do
    if official_ouroboros_plugin?(plugin), do: :official_ouroboros, else: :third_party_plugin
  end

  defp reserved_official_namespace_violation?(%{
         metadata: %{namespace_owner: :official_ouroboros}
       }) do
    false
  end

  defp reserved_official_namespace_violation?(entry) do
    Enum.any?([entry.slash | entry.aliases], &reserved_official_slash?/1)
  end

  defp reserved_official_slash?(slash) do
    MapSet.member?(@official_reserved_slashes, slash) or String.starts_with?(slash, "/ouroboros")
  end

  defp normalize_plugin_arg!(arg) when is_map(arg) do
    %{
      name: arg |> field("name", field(arg, :name, "")) |> to_string(),
      required?: arg |> field("required?", field(arg, "required", false)) |> truthy?(),
      description: arg |> field("description", field(arg, :description, "")) |> to_string()
    }
  end

  defp normalize_plugin_arg!(name) when is_binary(name) do
    %{name: name, required?: false, description: ""}
  end

  defp normalize_mcp_arg!(%{name: name, required?: required?, description: description}) do
    %{name: name, required?: required?, description: description}
  end

  defp normalize_mcp_arg!(arg) when is_map(arg) do
    %{
      name: arg |> field("name", "") |> to_string(),
      required?: arg |> field("required?", field(arg, "required", false)) |> truthy?(),
      description: arg |> field("description", "") |> to_string()
    }
  end

  defp mcp_tool_args(tool) when is_map(tool) do
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
        field(tool, "args", [])

      true ->
        []
    end
  end

  defp mcp_tool_list(envelope) do
    cond do
      is_list(field(envelope, "tools", nil)) -> field(envelope, "tools", nil)
      is_list(field(envelope, "entries", nil)) -> field(envelope, "entries", nil)
      is_list(get_in(envelope, ["result", "tools"])) -> get_in(envelope, ["result", "tools"])
      is_list(get_in(envelope, [:result, :tools])) -> get_in(envelope, [:result, :tools])
      true -> nil
    end
  end

  defp mcp_tool_entry?(entry) when is_map(entry) do
    is_binary(field(entry, "name", nil)) and
      (Map.has_key?(entry, "inputSchema") or Map.has_key?(entry, :inputSchema) or
         Map.has_key?(entry, "input_schema") or Map.has_key?(entry, :input_schema) or
         field(entry, "kind", "tool") in ["tool", :tool])
  end

  defp mcp_tool_entry?(_entry), do: false

  defp mcp_user_invocable?(entry) when is_map(entry) do
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

  defp mcp_user_invocable?(_entry), do: false

  defp mcp_invocability_metadata(entry) when is_map(entry) do
    annotations = field(entry, "annotations", %{})

    cond do
      explicit = mcp_invocability_value(entry, "user_invocable") ->
        mcp_invocability_metadata(:tool_user_invocable, explicit)

      explicit = mcp_invocability_value(entry, "userInvocable") ->
        mcp_invocability_metadata(:tool_user_invocable, explicit)

      explicit = mcp_invocability_value(annotations, "user_invocable") ->
        mcp_invocability_metadata(:annotation_user_invocable, explicit)

      explicit = mcp_invocability_value(annotations, "userInvocable") ->
        mcp_invocability_metadata(:annotation_user_invocable, explicit)

      true ->
        mcp_invocability_metadata(:default_user_invocable, true)
    end
  end

  defp mcp_invocability_metadata(source, raw_value) do
    %{
      user_invocable?: truthy_default_true?(raw_value),
      source: source,
      raw_value: raw_value,
      runnable?: true,
      method: "tools/call"
    }
  end

  defp mcp_invocability_value(entry, key) when is_map(entry) do
    cond do
      Map.has_key?(entry, key) -> Map.get(entry, key)
      Map.has_key?(entry, atom_key(key)) -> Map.get(entry, atom_key(key))
      true -> nil
    end
  end

  defp mcp_envelope_context(envelope) when is_map(envelope) do
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

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, atom_key(key), default))
  end

  defp atom_key(key) when is_atom(key), do: key

  defp atom_key("action"), do: :action
  defp atom_key("aliases"), do: :aliases
  defp atom_key("args"), do: :args
  defp atom_key("commands"), do: :commands
  defp atom_key("description"), do: :description
  defp atom_key("mcp_tool"), do: :mcp_tool
  defp atom_key("name"), do: :name
  defp atom_key("required"), do: :required
  defp atom_key("required?"), do: :required?
  defp atom_key("skills"), do: :skills
  defp atom_key("slash"), do: :slash
  defp atom_key("summary"), do: :summary
  defp atom_key("discovered_from"), do: :discovered_from
  defp atom_key("display_name"), do: :display_name
  defp atom_key("entries"), do: :entries
  defp atom_key("input_schema"), do: :input_schema
  defp atom_key("inputSchema"), do: :inputSchema
  defp atom_key("id"), do: :id
  defp atom_key("kind"), do: :kind
  defp atom_key("server_id"), do: :server_id
  defp atom_key("session_id"), do: :session_id
  defp atom_key("source_id"), do: :source_id
  defp atom_key("title"), do: :title
  defp atom_key("tools"), do: :tools
  defp atom_key("transport"), do: :transport
  defp atom_key("user_invocable"), do: :user_invocable
  defp atom_key("userInvocable"), do: :userInvocable
  defp atom_key(_key), do: :__missing_plugin_registry_key__

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
