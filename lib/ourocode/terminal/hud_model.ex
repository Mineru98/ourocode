defmodule Ourocode.Terminal.HudModel do
  @moduledoc """
  Compact bottom-HUD projection for the terminal chrome.

  The renderer owns pixels; this module owns the operator-facing summary of
  workflow, MCP, interview, and runtime state.
  """

  alias Ourocode.Model.Profile
  alias Ourocode.Terminal.{FrameSections, Screen, WorkflowRail}

  @type t :: %{
          required(:mode_chip) => String.t(),
          required(:placeholder) => String.t(),
          required(:left_status) => String.t(),
          required(:center_status) => String.t(),
          required(:segments) => [String.t()],
          required(:actions) => String.t(),
          required(:notification) => String.t() | nil
        }

  @spec build(map(), [{String.t(), [String.t()]}] | map(), atom(), map(), pos_integer()) :: t()
  def build(kv, sections, mode, opts, width)
      when is_map(kv) and is_map(opts) and is_integer(width) do
    sections = normalize_sections(sections)
    notification = first_notification(opts)

    %{
      mode_chip: mode_chip(mode, opts),
      placeholder: placeholder(mode, opts, width),
      left_status: left_status(kv, sections, opts),
      center_status: center_status(sections, opts, width),
      segments: segments(sections, opts, width),
      actions: actions(mode, opts, width, notification),
      notification: notification
    }
  end

  defp normalize_sections(sections) when is_list(sections), do: sections
  defp normalize_sections(_sections), do: []

  defp first_notification(%{notifications: [note | _rest]}) when is_binary(note), do: note
  defp first_notification(_opts), do: nil

  defp mode_chip(:palette, _opts), do: "palette"
  defp mode_chip(:model, _opts), do: "model"
  defp mode_chip(_mode, %{interview_decision: true}), do: "question"
  defp mode_chip(_mode, %{interview_paused: true}), do: "paused"
  defp mode_chip(_mode, %{wonder_focus: true}), do: "interview"
  defp mode_chip(_mode, %{streaming: true}), do: "thinking"

  defp mode_chip(_mode, opts) do
    cond do
      runtime_split_active?(opts) -> "mcp"
      workflow_active?(opts) -> "ooo"
      true -> "main"
    end
  end

  defp placeholder(_mode, %{interview_paused: true}, _width),
    do: "/answer <text> resumes; type normally to discuss"

  defp placeholder(_mode, %{interview_decision: true}, _width), do: ""
  defp placeholder(_mode, %{wonder_focus: true}, _width), do: ""
  defp placeholder(:palette, _opts, _width), do: "type to filter commands"

  defp placeholder(_mode, opts, _width) when map_size(opts) >= 0 do
    cond do
      prompt_busy?(opts) ->
        "Queue a follow-up; Esc interrupts"

      runtime_split_active?(opts) ->
        "Ask, or inspect MCP output with Up/Dn, j/k, 1-9"

      workflow_active?(opts) ->
        "Guide the run, answer checkpoints, or ask for evidence"

      true ->
        "Ask, / command, or ooo auto/pm/run"
    end
  end

  defp left_status(kv, sections, opts) do
    sessions = FrameSections.session_count(sections)
    status = Map.get(kv, "status", "")
    queued = Map.get(kv, "queued", "0")
    hooks = Map.get(kv, "hooks", "idle")
    runtime = runtime_label(Map.get(kv, "runtime", "?"), status)
    model_status = model_status(opts)

    []
    |> maybe(is_binary(model_status) and model_status != "", model_status)
    |> Kernel.++([runtime])
    |> maybe(sessions > 0, "#{sessions} active")
    |> maybe(queued != "0", "q#{queued}")
    |> maybe(hooks != "idle", "hooks #{hooks}")
    |> Enum.join("   ")
  end

  defp model_status(%{model_status: status}) when is_binary(status), do: status
  defp model_status(_opts), do: nil

  defp center_status(sections, opts, width) do
    sections
    |> segments(opts, width)
    |> Enum.join("   ")
  end

  defp segments(sections, opts, width) do
    parts =
      []
      |> maybe(workflow_summary(sections, opts, width))
      |> maybe(profile_summary(opts))
      |> maybe(mcp_summary(opts))
      |> maybe(interview_summary(opts))

    case parts do
      [] -> []
      _parts -> parts
    end
  end

  defp actions(_mode, _opts, _width, notification) when is_binary(notification), do: notification
  defp actions(_mode, %{workspace_active: true}, width, _notification), do: workspace_hints(width)
  defp actions(:palette, _opts, _width, _notification), do: "Up/Dn  Enter run  Esc"

  defp actions(_mode, %{interview_decision: true}, width, _notification) when width < 76,
    do: "Enter answer  1-3 choose  Esc"

  defp actions(_mode, %{interview_decision: true}, _width, _notification),
    do: "Enter answer  1-3 choose  Tab reasoning  Esc pause"

  defp actions(_mode, opts, width, _notification) do
    cond do
      runtime_split_active?(opts) and width < 76 -> "Up/Dn move  Enter open  Esc"
      runtime_split_active?(opts) -> "Up/Dn move  Enter open  1-9 jump  Esc"
      prompt_busy?(opts) -> "Esc interrupt  type follow-up"
      workflow_active?(opts) -> "Enter open  Esc pause"
      width < 52 -> "/  ooo  ^C"
      width < 76 -> "/ commands  ooo work  ^C"
      true -> "/ commands  ooo work  Up/^P history  ^C"
    end
  end

  defp workflow_summary(sections, opts, width) do
    workflow = Map.get(opts, :workflow, %{})

    cond do
      not workflow_active?(opts) ->
        nil

      width < 76 ->
        "run " <>
          compact_stage_skeleton(
            sections,
            Map.get(opts, :interview_reasoning, []),
            Map.get(opts, :mcp_activity, []),
            workflow
          )

      true ->
        rows =
          sections
          |> WorkflowRail.rows(
            Map.get(opts, :interview_reasoning, []),
            Map.get(opts, :mcp_activity, []),
            workflow
          )

        "run " <> compact_rows(rows, width)
    end
  end

  defp compact_rows(rows, width) do
    case active_rows(rows) do
      [] ->
        "ready"

      active ->
        active
        |> Enum.map(fn row ->
          row
          |> String.replace_prefix("● ", "")
          |> compact_stage_label()
        end)
        |> fit_tokens(max(width - 58, 24))
    end
  end

  defp active_rows(rows) do
    Enum.reject(rows, &ready_row?/1)
  end

  defp ready_row?(row), do: String.ends_with?(row, " ready")

  defp compact_stage_label("socratic " <> status), do: "socratic " <> status
  defp compact_stage_label("execute " <> status), do: "exec " <> status
  defp compact_stage_label("evidence recorded"), do: "evidence recorded"
  defp compact_stage_label("evidence " <> status), do: "evidence " <> status
  defp compact_stage_label("verify " <> status), do: "verify " <> status
  defp compact_stage_label("plan " <> status), do: "plan " <> status
  defp compact_stage_label(row), do: row

  defp fit_tokens(tokens, max_width) do
    tokens
    |> Enum.reduce_while("", fn token, acc ->
      next = if acc == "", do: token, else: acc <> " · " <> token

      if Screen.text_width(next) <= max_width do
        {:cont, next}
      else
        {:halt, acc}
      end
    end)
  end

  defp compact_stage_skeleton(sections, reasoning, mcp_activity, workflow) do
    WorkflowRail.rows(sections, reasoning, mcp_activity, workflow)
    |> active_rows()
    |> case do
      [] ->
        ["ready"]

      active ->
        active
    end
    |> Enum.map(fn row ->
      cond do
        row == "ready" -> "ready"
        String.contains?(row, "socratic") -> stage_token("socratic", row)
        String.contains?(row, "plan") -> stage_token("plan", row)
        String.contains?(row, "execute") -> stage_token("exec", row)
        String.contains?(row, "verify") -> stage_token("verify", row)
        String.contains?(row, "evidence") -> stage_token("evidence", row)
        true -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp stage_token(label, row) do
    if Regex.match?(
         ~r/\b(live|active|dispatching|waiting|retrying|needs user|evidence|recorded|done)\b/,
         row
       ) do
      label <> "*"
    else
      label
    end
  end

  defp mcp_summary(opts) do
    runtime_split = Map.get(opts, :runtime_split, %{})
    child_lines = Map.get(runtime_split, :child_lines, [])
    parent_count = runtime_split |> Map.get(:parent_lines, []) |> safe_length()
    child_count = child_count(child_lines)
    block_count = runtime_split |> Map.get(:block_ids, []) |> safe_length()
    activity_count = opts |> Map.get(:mcp_activity, []) |> safe_length()
    lead_child = lead_child_status(child_lines)

    cond do
      parent_count > 0 or child_count > 0 or block_count > 0 ->
        [
          "mcp #{mcp_counts(parent_count, child_count, block_count)}",
          lead_child
        ]
        |> Enum.reject(&(&1 == nil))
        |> Enum.join(" · ")

      activity_count > 0 ->
        "mcp #{activity_count} live"

      true ->
        nil
    end
  end

  defp profile_summary(opts) do
    opts
    |> Map.get(:workflow, %{})
    |> latest_run()
    |> run_profile()
    |> case do
      %{label: label, model_label: model_label} ->
        Profile.display_label(%{label: label, model_label: model_label})

      %{"label" => label, "model_label" => model_label} ->
        Profile.display_label(%{"label" => label, "model_label" => model_label})

      _none ->
        nil
    end
  end

  defp latest_run(%{latest_run_id: id, runs: runs}) when is_binary(id) and is_map(runs),
    do: Map.get(runs, id)

  defp latest_run(%{"latest_run_id" => id, "runs" => runs}) when is_binary(id) and is_map(runs),
    do: Map.get(runs, id)

  defp latest_run(_workflow), do: nil

  defp run_profile(%{model_profile: profile}) when is_map(profile), do: profile
  defp run_profile(%{"model_profile" => profile}) when is_map(profile), do: profile
  defp run_profile(_run), do: nil

  defp mcp_counts(parent_count, child_count, block_count) do
    [
      count_label(parent_count, "parent"),
      count_label(child_count, "pane"),
      count_label(block_count, "block")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp interview_summary(%{question_summary: summary}) when is_binary(summary) and summary != "",
    do: summary

  defp interview_summary(%{interview_decision: true}), do: "Q pending"
  defp interview_summary(%{wonder_focus: true}), do: "interview choosing"
  defp interview_summary(%{interview_paused: true}), do: "interview paused"

  defp interview_summary(%{interview_reasoning: reasoning})
       when is_list(reasoning) and reasoning != [],
       do: "reasoning live"

  defp interview_summary(_opts), do: nil

  defp runtime_split_active?(opts), do: get_in(opts, [:runtime_split, :active?]) == true

  defp workflow_active?(opts) do
    workflow = Map.get(opts, :workflow, %{})

    (is_map(workflow) and map_size(workflow) > 0) or
      Map.get(opts, :interview_reasoning, []) != [] or
      Map.get(opts, :mcp_activity, []) != []
  end

  defp prompt_busy?(opts),
    do: Map.get(opts, :live_turn_activity, []) != [] or Map.get(opts, :streaming, false)

  defp runtime_label(runtime, status) when runtime in ["?", "unknown", nil] do
    if status in ["healthy", "ready"], do: "ready", else: "main"
  end

  defp runtime_label(runtime, _status), do: runtime

  defp child_count(lines) when is_list(lines) do
    Enum.count(lines, fn
      %{text: "Child " <> _rest} -> true
      "Child " <> _rest -> true
      _other -> false
    end)
  end

  defp child_count(_lines), do: 0

  defp lead_child_status(lines) when is_list(lines) do
    lines
    |> Enum.map(fn
      %{text: "Child " <> rest} -> child_status_label(rest)
      "Child " <> rest -> child_status_label(rest)
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&child_priority/1)
    |> List.first()
  end

  defp lead_child_status(_lines), do: nil

  defp child_status_label(rest) do
    case String.split(rest, " · ", parts: 3) do
      [child_id, status | _tail] -> "#{child_id} #{status}"
      _other -> nil
    end
  end

  defp child_priority(label) do
    cond do
      Regex.match?(~r/(failed|error|blocked|attention)/i, label) -> 0
      Regex.match?(~r/(retrying|waiting|needs)/i, label) -> 1
      Regex.match?(~r/(active|streaming|working|running)/i, label) -> 2
      true -> 3
    end
  end

  defp safe_length(items) when is_list(items), do: length(items)
  defp safe_length(_items), do: 0

  defp count_label(0, _label), do: nil
  defp count_label(1, label), do: "1 #{label}"
  defp count_label(count, label), do: "#{count} #{label}s"

  defp workspace_hints(width) when width < 52, do: "workspace  Up/Dn  Enter"
  defp workspace_hints(width) when width < 76, do: "workspace  Up/Dn rows  Enter action"

  defp workspace_hints(_width),
    do: "workspace focus  Up/Dn rows  Enter row action  type to compose"

  defp maybe(list, nil), do: list
  defp maybe(list, ""), do: list
  defp maybe(list, item), do: list ++ [item]

  defp maybe(list, false, _item), do: list
  defp maybe(list, true, item), do: list ++ [item]
end
