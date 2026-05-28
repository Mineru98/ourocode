defmodule Ourocode.Terminal.Suggestions do
  @moduledoc false

  alias Ourocode.Terminal.{FileMention, Fuzzy, OooCommands, Palette}

  @spec ooo_suggestions(String.t(), atom(), boolean(), [{String.t(), String.t()}] | nil) :: list()
  def ooo_suggestions(prompt_buffer, :normal, false, commands) do
    trimmed = String.trim_leading(prompt_buffer)
    commands = commands || OooCommands.fallback()

    cond do
      trimmed == "ooo" ->
        OooCommands.starters(commands)

      String.starts_with?(trimmed, "ooo ") ->
        case completed_ooo_command(trimmed, commands) do
          nil ->
            query =
              trimmed
              |> String.replace_prefix("ooo ", "")
              |> String.trim()
              |> String.downcase()

            starter_suggestions(query, commands) ||
              commands
              |> Enum.map(fn {command, summary} -> {command, {command, summary}} end)
              |> Fuzzy.rank(query, limit: 8)

          command ->
            [command]
        end

      true ->
        []
    end
  end

  def ooo_suggestions(_prompt_buffer, _mode, _wonder_focus, _commands), do: []

  @spec completed_ooo_command?(String.t(), [{String.t(), String.t()}]) :: boolean()
  def completed_ooo_command?(prompt_buffer, commands) do
    not is_nil(completed_ooo_command(String.trim_leading(prompt_buffer), commands))
  end

  defp completed_ooo_command(trimmed, commands) do
    Enum.find(commands, fn {command, _summary} ->
      String.starts_with?(trimmed, command <> " ")
    end)
  end

  defp starter_suggestions(query, commands) do
    starters = OooCommands.starters(commands)

    matching =
      Enum.filter(starters, fn {command, _summary} ->
        command
        |> String.replace_prefix("ooo ", "")
        |> String.starts_with?(query)
      end)

    cond do
      query == "" -> starters
      matching != [] -> matching
      true -> nil
    end
  end

  @spec ooo_prompt?(term()) :: boolean()
  def ooo_prompt?(prompt_buffer) when is_binary(prompt_buffer) do
    trimmed = String.trim_leading(prompt_buffer)
    trimmed == "ooo" or String.starts_with?(trimmed, "ooo ")
  end

  def ooo_prompt?(_prompt_buffer), do: false

  @spec build_ooo_commands(boolean()) :: [{String.t(), String.t()}]
  def build_ooo_commands(test_run?), do: OooCommands.build(test_run?)

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
    FileMention.active_query(prompt_buffer, cursor)
  end

  @spec replace_active_file_mention(String.t(), non_neg_integer(), String.t()) ::
          {String.t(), non_neg_integer()}
  def replace_active_file_mention(buffer, cursor, path) do
    FileMention.replace_active(buffer, cursor, path)
  end

  @spec file_label(String.t()) :: String.t()
  def file_label(path), do: FileMention.label(path)
end
