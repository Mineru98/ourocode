defmodule Ourocode.Terminal.Suggestions do
  @moduledoc false

  alias Ourocode.Command.Registry
  alias Ourocode.Terminal.{Fuzzy, InputEditor, Palette, PromptStore}

  @ooo_fallback_commands [
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

  @spec ooo_suggestions(String.t(), atom(), boolean(), [{String.t(), String.t()}] | nil) :: list()
  def ooo_suggestions(prompt_buffer, :normal, false, commands) do
    trimmed = String.trim_leading(prompt_buffer)
    commands = commands || @ooo_fallback_commands

    cond do
      trimmed == "ooo" ->
        commands

      String.starts_with?(trimmed, "ooo ") ->
        query =
          trimmed
          |> String.replace_prefix("ooo ", "")
          |> String.trim()
          |> String.downcase()

        commands
        |> Enum.map(fn {command, summary} -> {command, {command, summary}} end)
        |> Fuzzy.rank(query, limit: 8)

      true ->
        []
    end
  end

  def ooo_suggestions(_prompt_buffer, _mode, _wonder_focus, _commands), do: []

  @spec ooo_prompt?(term()) :: boolean()
  def ooo_prompt?(prompt_buffer) when is_binary(prompt_buffer) do
    trimmed = String.trim_leading(prompt_buffer)
    trimmed == "ooo" or String.starts_with?(trimmed, "ooo ")
  end

  def ooo_prompt?(_prompt_buffer), do: false

  @spec build_ooo_commands(boolean()) :: [{String.t(), String.t()}]
  def build_ooo_commands(test_run?) do
    registry_commands =
      case Registry.load() do
        {:ok, registry} ->
          registry
          |> Registry.entries()
          |> Enum.filter(&ooo_registry_entry?/1)
          |> Enum.map(&ooo_registry_command/1)

        _error ->
          []
      end

    usage = if test_run?, do: %{}, else: PromptStore.command_usage()

    (@ooo_fallback_commands ++ registry_commands)
    |> Enum.uniq_by(fn {command, _summary} -> command end)
    |> rank_ooo_by_usage(usage)
  rescue
    _exception -> @ooo_fallback_commands
  end

  @spec ooo_choice(String.t(), non_neg_integer(), [{String.t(), String.t()}]) :: String.t()
  def ooo_choice(prompt_buffer, index, commands) do
    suggestions = ooo_suggestions(prompt_buffer, :normal, false, commands)
    clamped = Palette.clamp(index, length(suggestions))

    case Enum.at(suggestions, clamped) do
      {command, _summary} -> command
      _none -> String.trim(prompt_buffer)
    end
  end

  @spec resource_mention_suggestions(String.t(), atom(), boolean(), map()) :: list()
  def resource_mention_suggestions(prompt_buffer, :normal, false, opts) do
    case active_resource_mention_query(prompt_buffer) do
      nil ->
        []

      query ->
        opts
        |> Map.get(:resource_mentions, [])
        |> Enum.map(fn {uri, label} -> {uri, {uri, label}} end)
        |> Fuzzy.rank(query, limit: 8)
    end
  end

  def resource_mention_suggestions(_prompt_buffer, _mode, _wonder_focus, _opts), do: []

  @spec active_resource_mention_query(String.t()) :: String.t() | nil
  def active_resource_mention_query(prompt_buffer) when is_binary(prompt_buffer) do
    case Regex.run(~r/(?:^|\s)@mcp:([^\s@]*)$/u, prompt_buffer) do
      [_, query] -> query
      _none -> nil
    end
  end

  @spec active_file_mention_query(String.t(), non_neg_integer()) :: String.t() | nil
  def active_file_mention_query(prompt_buffer, cursor) when is_binary(prompt_buffer) do
    graphemes = String.graphemes(prompt_buffer)
    cursor = InputEditor.clamp_cursor(cursor, length(graphemes))
    prefix = graphemes |> Enum.take(cursor) |> Enum.join()

    case Regex.run(~r/(?:^|\s)@([^\s@]*)$/u, prefix) do
      [_, query] -> query
      _none -> nil
    end
  end

  @spec replace_active_file_mention(String.t(), non_neg_integer(), String.t()) ::
          {String.t(), non_neg_integer()}
  def replace_active_file_mention(buffer, cursor, path) do
    graphemes = String.graphemes(buffer)
    cursor = InputEditor.clamp_cursor(cursor, length(graphemes))
    {left, right} = Enum.split(graphemes, cursor)
    prefix = Enum.join(left)

    case Regex.run(~r/(^|\s)@([^\s@]*)$/u, prefix, return: :index) do
      [{start, _len}, {_sep_start, sep_len}, _query] ->
        before = binary_part(prefix, 0, start)
        sep = binary_part(prefix, start, sep_len)
        replacement = sep <> "@" <> path <> " "
        new_prefix = before <> replacement
        {new_prefix <> Enum.join(right), String.length(new_prefix)}

      _none ->
        text = "@" <> path <> " "
        {buffer <> text, String.length(buffer) + String.length(text)}
    end
  end

  @spec file_label(String.t()) :: String.t()
  def file_label(path) do
    path
    |> Path.dirname()
    |> case do
      "." -> "project file"
      dir -> dir
    end
  end

  defp rank_ooo_by_usage(commands, usage) when is_map(usage) do
    commands
    |> Enum.with_index()
    |> Enum.sort_by(fn {{command, _summary}, index} -> {-Map.get(usage, command, 0), index} end)
    |> Enum.map(fn {command, _index} -> command end)
  end

  defp ooo_registry_entry?(entry) do
    entry.source in [:plugin, :dynamic_skill] or
      String.starts_with?(entry.name, "ouroboros") or
      entry.name in [
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
      ]
  end

  defp ooo_registry_command(entry) do
    name =
      entry.name
      |> String.replace_prefix("ouroboros-", "")
      |> String.replace_prefix("ouroboros_", "")

    {"ooo " <> name, entry.summary}
  end
end
