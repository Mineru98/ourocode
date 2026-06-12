defmodule Ourocode.Terminal.TranscriptRows do
  @moduledoc """
  Converts terminal activity lines into styled transcript rows.
  """

  @type row :: %{
          required(:rail) => String.t() | nil,
          required(:rail_style) => atom(),
          required(:text) => String.t(),
          required(:text_style) => atom()
        }

  @spec rows([String.t()] | nil) :: [row()]
  def rows(activity) when activity in [nil, []], do: []

  def rows(activity) when is_list(activity) do
    activity
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reduce({[], nil}, &fold_line/2)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == :sep))
    |> Enum.map(&render_row/1)
  end

  def rows(_activity), do: []

  @spec workspace_activity?([String.t()] | nil) :: boolean()
  def workspace_activity?([first | _rest]) when is_binary(first), do: workspace_line?(first)
  def workspace_activity?(_activity), do: false

  @spec paused_interview_discussion([String.t()] | nil) :: [String.t()]
  def paused_interview_discussion(activity) when activity in [nil, []], do: []

  def paused_interview_discussion(activity) when is_list(activity) do
    activity
    |> Enum.reduce({[], nil}, fn line, {kept, role} ->
      trimmed = String.trim(line)

      cond do
        paused_interview_noise?(trimmed) ->
          {kept, nil}

        String.starts_with?(trimmed, "you> ") or String.starts_with?(trimmed, "> ") ->
          {[line | kept], :user}

        String.starts_with?(trimmed, "ourocode> ") ->
          {[line | kept], :assistant}

        role in [:user, :assistant] and trimmed != "" and not system_line?(trimmed) ->
          {[line | kept], role}

        true ->
          {kept, nil}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  def paused_interview_discussion(_activity), do: []

  defp fold_line(line, {rows, role}) do
    cond do
      String.starts_with?(line, "+-- ") ->
        {rows, :ssot}

      role == :ssot and line == "+--" ->
        {rows, nil}

      role == :ssot ->
        case strip_prefix(line, "| ") do
          nil -> {rows, :ssot}
          inner -> {[{:system, humanize(inner)}, :sep | rows], :ssot}
        end

      rest = strip_prefix(line, "you> ") ->
        push_block(rows, :user, "Answer", rest)

      rest = strip_prefix(line, "ourocode> ") ->
        push_block(rows, :assistant, "OUROCODE", rest)

      rest = strip_prefix(line, "> ") ->
        push_block(rows, :user, "Answer", rest)

      status_line?(line) ->
        {[{:status, line}, :sep | rows], nil}

      live_line?(line) ->
        {[{:live, String.trim(line)}, :sep | rows], nil}

      system_line?(line) ->
        {[{:system, line}, :sep | rows], nil}

      line == "" ->
        {rows, role}

      workspace_line?(line) ->
        {[{:workspace_header, line}, :sep | rows], :workspace}

      role == :workspace and workspace_section?(line) ->
        {[{:workspace_section, String.trim(line)} | rows], :workspace}

      role == :workspace and workspace_selected_row?(line) ->
        {[{:workspace_selected, String.trim(line)} | rows], :workspace}

      role == :workspace and workspace_record_row?(line) ->
        {[{:workspace_record, String.trim(line)} | rows], :workspace}

      role == :workspace and workspace_detail_row?(line) ->
        {[{:workspace_detail, String.trim(line)} | rows], :workspace}

      role in [:user, :assistant] ->
        {[{{:body, role}, line} | rows], role}

      true ->
        {[{:system, line}, :sep | rows], nil}
    end
  end

  defp push_block(rows, role, label, first) do
    rows = [{{:body, role}, first}, {{:label, role}, label}, :sep | rows]
    {rows, role}
  end

  defp strip_prefix(line, prefix) do
    if String.starts_with?(line, prefix),
      do: String.replace_prefix(line, prefix, ""),
      else: nil
  end

  defp system_line?(line) do
    String.starts_with?(line, [
      "queued ",
      "Signed ",
      "Sign in",
      "Login",
      "Not connected",
      "No model",
      "Model error",
      "Connect ChatGPT",
      "model:"
    ]) or String.contains?(line, ["error", "failed"])
  end

  defp status_line?(line) do
    line in [
      "Interview cancelled.",
      "Command held. Press Esc to discuss, or /cancel to stop this interview."
    ]
  end

  defp live_line?(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, ["live: ", "pulse: "])
  end

  defp workspace_line?(line) do
    trimmed = String.trim(line)

    trimmed in [
      "Agents",
      "Connected tools",
      "Plugins",
      "Configuration",
      "Sandbox",
      "Sessions",
      "Resume",
      "Guided Work",
      "Auto Run",
      "PM Interview",
      "Socratic Interview"
    ] or
      String.contains?(line, " workspace · ") or
      String.ends_with?(line, " workspace") or
      String.match?(
        trimmed,
        ~r/\A.+ · (plugins|guided work|connected tools|configuration|sandbox|sessions|resume|interview)\z/
      )
  end

  defp workspace_section?(line) do
    trimmed = String.trim(line)

    trimmed in [
      "Rows",
      "Detail",
      "Actions",
      "List",
      "Selected",
      "Use",
      "Available",
      "Current",
      "Work",
      "Focus",
      "Start",
      "Run",
      "Move"
    ] or String.match?(trimmed, ~r/\A.+; \d+ .+\z/) or
      String.starts_with?(line, [
        "Status · ",
        "Actions · ",
        "Shortcuts · ",
        "Use · ",
        "Use:",
        "Try ",
        "Keys · ",
        "Keys:",
        "Move with ",
        "Start · ",
        "Run · ",
        "Run:",
        "Shortcuts:",
        "Move · ",
        "Next · ",
        "Then:",
        "Try ",
        "Keyboard ",
        "Move with ",
        "Next step "
      ])
  end

  defp workspace_selected_row?(line), do: String.starts_with?(String.trim(line), ">> ")

  defp workspace_record_row?(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "-- ") or Regex.match?(~r/^[^\s].* · /, trimmed)
  end

  defp workspace_detail_row?(line), do: String.starts_with?(line, "  ")

  defp paused_interview_noise?(trimmed) when is_binary(trimmed) do
    downcased = String.downcase(trimmed)

    trimmed in ["", "empty", "-- empty"] or
      String.starts_with?(trimmed, "-- ") or
      String.contains?(downcased, [
        "[workflow-starting]",
        "queued task ",
        "interview paused",
        "workflow",
        "dispatching_input"
      ])
  end

  defp paused_interview_noise?(_trimmed), do: false

  defp render_row(:sep), do: %{rail: nil, rail_style: :text, text: "", text_style: :text}

  # Speaker colour identity: the user reads in amber (accent), the assistant
  # in teal (brand). The coloured rail + coloured label make the dialectic
  # legible at a glance instead of two near-identical grey blocks.
  defp render_row({{:label, :user}, text}),
    do: %{rail: nil, rail_style: :text, text: text, text_style: :accent}

  defp render_row({{:label, :assistant}, text}),
    do: %{rail: nil, rail_style: :text, text: text, text_style: :brand}

  defp render_row({{:label, _role}, text}),
    do: %{rail: nil, rail_style: :text, text: text, text_style: :label}

  defp render_row({{:body, :user}, text}),
    do: %{rail: "│", rail_style: :accent, text: text, text_style: :strong}

  defp render_row({{:body, :assistant}, text}),
    do: %{rail: "│", rail_style: :brand, text: text, text_style: :text}

  defp render_row({:system, text}),
    do: %{rail: nil, rail_style: :text, text: "• " <> humanize(text), text_style: :muted}

  defp render_row({:status, text}),
    do: %{rail: "│", rail_style: :accent, text: humanize(text), text_style: :strong}

  defp render_row({:live, text}),
    do: %{rail: "│", rail_style: :accent, text: humanize(text), text_style: :accent}

  defp render_row({:workspace_header, text}),
    do: %{rail: nil, rail_style: :text, text: humanize(text), text_style: :label}

  defp render_row({:workspace_section, text}),
    do: %{rail: nil, rail_style: :text, text: humanize(text), text_style: :accent}

  defp render_row({:workspace_selected, text}),
    do: %{rail: "│", rail_style: :accent, text: humanize(text), text_style: :strong}

  defp render_row({:workspace_record, text}),
    do: %{rail: "│", rail_style: :dim, text: humanize(text), text_style: :text}

  defp render_row({:workspace_detail, text}),
    do: %{rail: "│", rail_style: :dim, text: humanize(text), text_style: :muted}

  @spec humanize(String.t()) :: String.t()
  def humanize(line) do
    line
    |> String.replace(~r/\s+(region|x|y|w|h)=\S+/, "")
    |> String.replace("[OFFICIAL]", "OFFICIAL")
    |> String.replace("[THIRD-PARTY]", "THIRD-PARTY")
    |> String.replace(~r/\b(id|label|state|version|source)=/, "")
    |> String.replace(~r/\s{2,}/, " ")
    |> String.trim()
  end
end
