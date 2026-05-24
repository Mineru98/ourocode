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
        push_block(rows, :user, "YOU", rest)

      rest = strip_prefix(line, "ourocode> ") ->
        push_block(rows, :assistant, "OUROCODE", rest)

      rest = strip_prefix(line, "> ") ->
        push_block(rows, :user, "YOU", rest)

      system_line?(line) ->
        {[{:system, line}, :sep | rows], nil}

      line == "" ->
        {rows, role}

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

  defp render_row({{:label, _role}, text}),
    do: %{rail: nil, rail_style: :text, text: text, text_style: :label}

  defp render_row({{:body, :user}, text}),
    do: %{rail: "|", rail_style: :accent, text: text, text_style: :strong}

  defp render_row({{:body, :assistant}, text}),
    do: %{rail: "|", rail_style: :dim, text: text, text_style: :text}

  defp render_row({:system, text}),
    do: %{rail: nil, rail_style: :text, text: "-- " <> humanize(text), text_style: :muted}

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
