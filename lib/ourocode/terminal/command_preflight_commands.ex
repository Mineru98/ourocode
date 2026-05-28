defmodule Ourocode.Terminal.CommandPreflightCommands do
  @moduledoc """
  Read-only renderers for command capability preflight.
  """

  alias Ourocode.Command.CapabilityPreflight

  @actions [:show_preflight, :show_verify]

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec render(:show_preflight, map(), map(), map()) :: {:ok, map()}
  def render(:show_preflight, command_event, state, registry) do
    input = command_event.args |> Enum.join(" ") |> String.trim()
    preflight = CapabilityPreflight.resolve(registry, input)

    IO.puts(state.output, render_text(preflight))

    {:ok, %{preflight: preflight}}
  end

  def render(:show_verify, _command_event, state, _registry) do
    text = verify_text()
    IO.puts(state.output, text)

    {:ok,
     %{verify: %{status: :ready, command: "ourocode --verify --format json --project-dir ."}}}
  end

  defp verify_text do
    """
    verify: ready
      checks: startup, plugins, preflight, guided work, real terminal replay
      command: ourocode --verify --format json --project-dir .
      evidence: JSON summary plus terminal render snapshots
      next: run the command above from this workspace
    """
    |> String.trim_trailing()
  end

  def render_text(%{shell: shell, side_effects: side_effects} = preflight) do
    [
      "preflight: #{preflight.status}",
      "  command: #{preflight.input}",
      "  action: #{shell.summary}",
      "  status: #{shell_status(preflight.status, shell.risk)}",
      "  execution: #{execution_summary(side_effects)}",
      reason_line(preflight),
      "  review: #{shell.review}",
      shell_next_line(preflight.status)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @spec render_text(map()) :: String.t()
  def render_text(%{status: :missing, input: input, reason: reason}) do
    """
    preflight: missing
      input: #{blank(input)}
      reason: #{reason}
    """
    |> String.trim_trailing()
  end

  def render_text(
        %{status: status, capability: capability, match: match, trust: trust} = preflight
      ) do
    side_effects =
      preflight
      |> Map.get(:side_effects, %{})
      |> Map.put(:workflow, workflow_kind(capability, Map.get(preflight, :input)))

    [
      "preflight: #{status}",
      "  command: #{display_command(match, capability, preflight)}",
      "  action: #{action_summary(capability)}",
      "  status: #{status_summary(status, trust)}",
      "  execution: #{execution_summary(side_effects)}",
      reason_line(preflight),
      next_line(status, capability)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp reason_line(%{reason: reason}), do: "  reason: #{reason}"
  defp reason_line(_preflight), do: nil

  defp display_command(
         %{token: token, canonical: canonical, type: :alias},
         _capability,
         _preflight
       ),
       do: "#{token} -> #{canonical}"

  defp display_command(_match, _capability, %{input: input}) when is_binary(input) do
    case String.trim(input) do
      "" -> "/"
      text -> text
    end
  end

  defp display_command(_match, capability, _preflight), do: capability.slash

  defp action_summary(%{run_spec: %{action: :workflow}}),
    do: "start guided work"

  defp action_summary(%{run_spec: %{"action" => "workflow"}}),
    do: "start guided work"

  defp action_summary(%{slash: "/ooo"}), do: "start guided work"
  defp action_summary(%{run_spec: %{action: action}}), do: humanize(action)
  defp action_summary(%{run_spec: %{"action" => action}}), do: humanize(action)
  defp action_summary(_capability), do: "run this command"

  defp status_summary(:ready, %{status: :trusted}), do: "ready; trusted plugin"
  defp status_summary(:ready, _trust), do: "ready"
  defp status_summary(:blocked, %{status: :requires_approval}), do: "blocked; approval required"
  defp status_summary(:blocked, _trust), do: "blocked"
  defp status_summary(status, _trust), do: to_string(status)

  defp execution_summary(%{execution: :none, workflow: workflow}) when workflow in [:auto, "auto"],
    do: "approval-gated workflow; no files change during preflight"

  defp execution_summary(%{execution: :none}), do: "preview only"
  defp execution_summary(%{execution: execution}), do: humanize(execution)
  defp execution_summary(_side_effects), do: "preview only"

  defp workflow_kind(%{run_spec: run_spec}, input) when is_map(run_spec) do
    action = Map.get(run_spec, :action, Map.get(run_spec, "action"))

    if action in [:workflow, "workflow"] do
      workflow_arg(input)
    end
  end

  defp workflow_kind(_capability, _input), do: nil

  defp workflow_arg(input) when is_binary(input) do
    input
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.drop(1)
    |> List.first()
  end

  defp workflow_arg(_input), do: nil

  defp next_line(:ready, %{run_spec: %{action: :workflow}}),
    do: "  ready: Enter starts the approval-gated workflow"

  defp next_line(:ready, _capability), do: "  ready: Enter runs the reviewed command"
  defp next_line(_status, _capability), do: "  blocked: resolve the issue above"

  defp shell_status(:blocked, risk), do: "blocked; #{humanize(risk)} risk"
  defp shell_status(:ready, risk), do: "reviewed; #{humanize(risk)} risk"
  defp shell_status(status, risk), do: "#{status}; #{humanize(risk)} risk"

  defp shell_next_line(:ready), do: "  next: run only if these side effects are intended"
  defp shell_next_line(_status), do: "  next: inspect or rewrite the command before running"

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
  end

  defp blank(""), do: "<empty>"
  defp blank(value), do: value
end
