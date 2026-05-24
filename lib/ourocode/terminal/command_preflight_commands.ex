defmodule Ourocode.Terminal.CommandPreflightCommands do
  @moduledoc """
  Read-only renderers for command capability preflight.
  """

  alias Ourocode.Command.CapabilityPreflight

  @actions [:show_preflight]

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec render(:show_preflight, map(), map(), map()) :: {:ok, map()}
  def render(:show_preflight, command_event, state, registry) do
    input = command_event.args |> Enum.join(" ") |> String.trim()
    preflight = CapabilityPreflight.resolve(registry, input)

    IO.puts(state.output, render_text(preflight))

    {:ok, %{preflight: preflight}}
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
    side_effects = Map.get(preflight, :side_effects, %{})

    [
      "preflight: #{status}",
      "  command: #{capability.slash}",
      "  match: #{match.token} -> #{match.canonical} (#{match.type})",
      "  source: #{capability.source}/#{capability.source_id}",
      "  run: #{run_summary(capability.run_spec)}",
      "  trust: #{trust.status}",
      "  execution: #{Map.get(side_effects, :execution, :unknown)}",
      reason_line(preflight),
      plugin_line(capability),
      risk_line(side_effects)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp reason_line(%{reason: reason}), do: "  reason: #{reason}"
  defp reason_line(_preflight), do: nil

  defp plugin_line(%{metadata: %{plugin_id: nil}}), do: nil
  defp plugin_line(%{metadata: %{plugin_id: plugin_id}}), do: "  plugin: #{plugin_id}"

  defp risk_line(%{risk_class: :not_applicable}), do: nil
  defp risk_line(%{risk_class: risk_class}), do: "  risk: #{risk_class}"
  defp risk_line(_side_effects), do: nil

  defp run_summary(run_spec) do
    run_spec
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
    |> Enum.join(" ")
  end

  defp blank(""), do: "<empty>"
  defp blank(value), do: value
end
