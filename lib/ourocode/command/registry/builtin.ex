defmodule Ourocode.Command.Registry.Builtin do
  @moduledoc """
  Builtin slash command definitions and normalization.
  """

  alias Ourocode.Command.RegistryEntryAdapter

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
      name: "preflight",
      slash: "/preflight",
      aliases: [],
      category: :discovery,
      summary: "Resolve a command capability without executing it.",
      args: [
        %{
          name: "command",
          required?: true,
          description: "Command-shaped input to resolve, such as /plugins"
        }
      ],
      run_spec: %{kind: :builtin_action, action: :show_preflight}
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

  @spec entries() :: [map()]
  def entries do
    Enum.map(@builtin_definitions, &normalize!/1)
  end

  @spec interrupt_definition() :: map()
  def interrupt_definition, do: @interrupt_definition

  @spec cancel_definition() :: map()
  def cancel_definition, do: @cancel_definition

  @spec normalize!(map()) :: map()
  def normalize!(definition) do
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

  defp normalize_slash(command) when is_binary(command) do
    command = String.trim(command)

    if String.starts_with?(command, "/") do
      command
    else
      "/#{command}"
    end
  end
end
