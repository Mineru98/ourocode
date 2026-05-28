defmodule Ourocode.Terminal.WorkspaceText do
  @moduledoc false

  @spec render(map() | nil) :: String.t()
  def render(nil), do: ""

  def render(workspace) when is_map(workspace) do
    [
      header(workspace),
      summary_line(workspace),
      record_lines(records(workspace), selected(workspace)),
      detail_lines(detail(workspace), value(workspace, :kind, "workspace")),
      action_lines(actions(workspace)),
      shortcuts_line(workspace),
      next_line(workspace)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp header(workspace) do
    title = value(workspace, :title, "Workspace")
    kind = value(workspace, :kind, "workspace")
    label = kind_label(kind)

    if same_header_meaning?(title, label) do
      title
    else
      "#{title} · #{label}"
    end
  end

  defp summary_line(workspace) do
    count = workspace |> records() |> length()
    status = value(workspace, :status, "ready")

    case value(workspace, :kind, "workspace") do
      "agents" ->
        "#{sentence_status(status)}; #{count} #{plural(count, "lane")}"

      "mcps" ->
        "#{sentence_status(status)}; #{count} connected #{plural(count, "tool")}"

      "plugins" ->
        "#{sentence_status(status)}; #{count} installed #{plural(count, "plugin")}"

      _other ->
        "#{sentence_status(status)}; #{count} #{plural(count, "choice")}"
    end
  end

  defp record_lines([], _selected), do: ["  nothing here yet"]

  defp record_lines(records, selected) do
    {visible, hidden} = visible_records(records, selected)

    lines =
      Enum.map(visible, fn record ->
        marker = if value(record, :id) == selected, do: ">>", else: "  "
        title = value(record, :title, value(record, :id, "record"))
        state = value(record, :state, "ready")
        health = value(record, :health, "")
        suffix = status_suffix(state, health)
        suffix = if suffix == "", do: "", else: " - " <> suffix
        "  #{marker} #{title}#{suffix}"
      end)

    if hidden > 0, do: lines ++ ["  #{hidden} more choices below"], else: lines
  end

  defp visible_records(records, selected) do
    limit = 5

    if length(records) <= limit do
      {records, 0}
    else
      selected_index = Enum.find_index(records, &(value(&1, :id) == selected)) || 0
      start = selected_index |> min(length(records) - limit) |> max(0)
      visible = Enum.slice(records, start, limit)
      {visible, length(records) - length(visible)}
    end
  end

  defp detail_lines(detail, kind) do
    title = value(detail, :title, "No record selected.")
    state = value(detail, :state, "empty")
    fields = value(detail, :fields, %{})

    [
      "",
      detail_heading(title, state),
      field_lines(fields, kind)
    ]
  end

  defp field_lines(fields, kind) when is_map(fields) do
    fields
    |> Enum.filter(fn {key, _value} -> visible_field?(kind, key) end)
    |> Enum.sort_by(fn {key, _value} -> {field_order(key), to_string(key)} end)
    |> Enum.map(fn {key, field_value} ->
      values = field_value |> List.wrap() |> Enum.map(&format_value/1) |> Enum.join(", ")
      "  " <> field_sentence(kind, key, values)
    end)
  end

  defp field_lines(_fields, _kind), do: []

  defp action_lines([]), do: []

  defp action_lines(actions) when is_list(actions) do
    text =
      actions
      |> Enum.map(&compact_action_text/1)
      |> Enum.join(" | ")

    [action_prefix(actions) <> text]
  end

  defp shortcuts_line(workspace) do
    shortcuts = value(workspace, :shortcuts, [])
    text = Enum.join(List.wrap(shortcuts), "; ")
    if text == "", do: nil, else: "Use " <> text
  end

  defp next_line(workspace) do
    case value(workspace, :next, nil) do
      nil -> nil
      "" -> nil
      next -> to_string(next)
    end
  end

  defp compact_action_text(action) when is_map(action) do
    enabled = if value(action, :enabled, true), do: "", else: " disabled"

    command = action |> value(:command, "") |> to_string()
    display = value(action, :display) || action_display(command, action)
    display <> enabled
  end

  defp compact_action_text(_action), do: ""

  defp status_suffix(state, health) do
    [state, health]
    |> Enum.map(&format_status_part/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  defp detail_heading(title, state) when state in [nil, "", "empty"], do: title
  defp detail_heading(title, state), do: "#{title} #{to_string(state)}"

  defp action_prefix(actions) do
    command =
      actions
      |> List.wrap()
      |> Enum.find_value("", fn action -> value(action, :command, "") end)
      |> to_string()

    if String.starts_with?(command, "ooo "), do: "Start ", else: "Open "
  end

  defp sentence_status(status) do
    status
    |> to_string()
    |> String.replace(" · ", ", ")
  end

  defp kind_label("agents"), do: "guided work"
  defp kind_label("mcps"), do: "connected tools"
  defp kind_label("plugins"), do: "plugins"
  defp kind_label("config"), do: "configuration"
  defp kind_label("sandbox"), do: "sandbox"
  defp kind_label("sessions"), do: "sessions"
  defp kind_label("resume"), do: "resume"
  defp kind_label("workflow"), do: "guided work"
  defp kind_label("interview"), do: "interview"
  defp kind_label(kind), do: to_string(kind)

  defp same_header_meaning?(title, label) do
    title = normalize_header_part(title)
    label = normalize_header_part(label)
    title == label or singularize(title) == singularize(label)
  end

  defp normalize_header_part(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end

  defp singularize(value), do: String.replace_suffix(value, "s", "")

  defp format_status_part(value) when value in [nil, ""], do: ""
  defp format_status_part(value), do: value |> to_string() |> String.trim()

  defp records(workspace), do: value(workspace, :records, [])
  defp selected(workspace), do: value(workspace, :selected, nil)
  defp detail(workspace), do: value(workspace, :detail, %{})
  defp actions(workspace), do: value(workspace, :actions, [])

  defp field_order(key) do
    case to_string(key) do
      "phase" -> 0
      "step" -> 0
      "task" -> 1
      "current" -> 2
      "progress" -> 3
      "target" -> 4
      "elapsed" -> 5
      "controls" -> 6
      "activity" -> 7
      "evidence" -> 8
      _other -> 20
    end
  end

  defp visible_field?(kind, key) when kind in ["agents", "workflow", "interview"] do
    to_string(key) in ["phase", "step", "task", "current", "progress"]
  end

  defp visible_field?(_kind, _key), do: true

  defp field_sentence(kind, key, values) when kind in ["agents", "workflow", "interview"] do
    case to_string(key) do
      "phase" -> "stage " <> values
      "step" -> "stage " <> values
      "task" -> task_sentence(values)
      "current" -> sentence_value(values)
      "progress" -> "progress " <> values
      "controls" -> "controls " <> values
      _other -> human_field(key, values)
    end
  end

  defp field_sentence(kind, key, values) when kind in ["plugins", "mcps", "config"] do
    case to_string(key) do
      "role" -> sentence_value(values)
      "setup" -> sentence_value(values)
      "capabilities" -> "adds " <> values
      "source" -> sentence_value(values)
      "workflows" -> "offers " <> values
      "access" -> sentence_value(values)
      _other -> human_field(key, values)
    end
  end

  defp field_sentence(_kind, key, values), do: human_field(key, values)

  defp task_sentence("start with " <> _rest = values), do: values
  defp task_sentence(values), do: "start with " <> values

  defp human_field(key, values) do
    label = key |> to_string() |> String.replace("_", " ")
    label <> " " <> values
  end

  defp sentence_value(""), do: ""

  defp sentence_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> capitalize_ascii()
  end

  defp capitalize_ascii(<<first, rest::binary>>) when first in ?a..?z,
    do: <<first - 32>> <> rest

  defp capitalize_ascii(value), do: value

  defp action_display("/pane " <> _id, action), do: value(action, :label, "Focus work")
  defp action_display(command, _action), do: command

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value), do: to_string(value)

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_map, _key, default), do: default
end
