defmodule Ourocode.Terminal.OooCommands do
  @moduledoc """
  Builds the `ooo` command catalog used by prompt suggestions.
  """

  alias Ourocode.Command.Registry
  alias Ourocode.Terminal.PromptStore

  @fallback [
    {"ooo interview", "clarify requirements through a Socratic interview"},
    {"ooo pm", "shape product requirements through a PM interview"},
    {"ooo auto", "interview, generate a Seed, and execute automatically"},
    {"ooo clarify", "turn vague requirements into a concrete direction"},
    {"ooo seed", "generate a validated Seed from the current interview"},
    {"ooo run", "execute a Seed specification"},
    {"ooo evolve", "run one evolutionary generation"},
    {"ooo ralph", "run an iterative Ralph loop"},
    {"ooo qa", "evaluate an artifact against a quality bar"},
    {"ooo evaluate", "run the three-stage execution evaluator"},
    {"ooo status", "inspect session status and drift"},
    {"ooo cancel", "cancel a stuck or orphaned execution"},
    {"ooo brownfield", "scan and manage repository context"},
    {"ooo publish", "publish Seed requirements as GitHub issues"},
    {"ooo resume-session", "list or resume in-flight Ouroboros sessions"},
    {"ooo help", "show Ouroboros commands and agents"},
    {"ooo tutorial", "learn Ouroboros hands-on"},
    {"ooo update", "check for Ouroboros updates"}
  ]

  @core_names MapSet.new([
                "interview",
                "pm",
                "auto",
                "clarify",
                "seed",
                "run",
                "evolve",
                "ralph",
                "qa",
                "evaluate",
                "status",
                "cancel",
                "brownfield",
                "publish",
                "resume-session",
                "help",
                "tutorial",
                "update"
              ])

  @spec fallback() :: [{String.t(), String.t()}]
  def fallback, do: @fallback

  @spec build(boolean()) :: [{String.t(), String.t()}]
  def build(test_run?) do
    usage = if test_run?, do: %{}, else: PromptStore.command_usage()

    (@fallback ++ registry_commands())
    |> Enum.uniq_by(fn {command, _summary} -> command end)
    |> rank_by_usage(usage)
  rescue
    _exception -> @fallback
  end

  @spec registry_command(map()) :: {String.t(), String.t()}
  def registry_command(entry) do
    name =
      entry.name
      |> String.replace_prefix("ouroboros-", "")
      |> String.replace_prefix("ouroboros_", "")

    {"ooo " <> name, entry.summary}
  end

  @spec registry_entry?(map()) :: boolean()
  def registry_entry?(entry) do
    entry.source in [:plugin, :dynamic_skill] or
      String.starts_with?(entry.name, "ouroboros") or
      MapSet.member?(@core_names, entry.name)
  end

  @spec rank_by_usage([{String.t(), String.t()}], map()) :: [{String.t(), String.t()}]
  def rank_by_usage(commands, usage) when is_map(usage) do
    commands
    |> Enum.with_index()
    |> Enum.sort_by(fn {{command, _summary}, index} -> {-Map.get(usage, command, 0), index} end)
    |> Enum.map(fn {command, _index} -> command end)
  end

  defp registry_commands do
    case Registry.load() do
      {:ok, registry} ->
        registry
        |> Registry.entries()
        |> Enum.filter(&registry_entry?/1)
        |> Enum.map(&registry_command/1)

      _error ->
        []
    end
  end
end
