defmodule Ourocode.Command.CapabilityPreflight do
  @moduledoc """
  Read-only capability resolution and preflight projection.

  This module is intentionally narrow: it resolves command-shaped input against
  the already-loaded command registry and projects what would run without
  executing, trusting, installing, or mutating plugin state.
  """

  alias Ourocode.Command.CapabilityPreflight.Projection
  alias Ourocode.Command.CapabilityPreflight.Trust
  alias Ourocode.Command.Registry

  @type status :: :ready | :blocked | :missing
  @type trust_status :: :trusted | :requires_approval | :unknown | :not_applicable

  @type t :: %{
          required(:status) => status(),
          required(:input) => String.t(),
          optional(:reason) => atom(),
          optional(:capability) => map(),
          optional(:match) => map(),
          optional(:trust) => map(),
          optional(:side_effects) => map()
        }

  @spec resolve(map(), String.t()) :: t()
  def resolve(registry, input) when is_map(registry) and is_binary(input) do
    case command_token(input) do
      {:error, reason} ->
        %{status: :missing, input: input, reason: reason}

      {:ok, token} ->
        case Registry.resolve(registry, token) do
          {:ok, resolved} -> preflight(input, resolved)
          :error -> %{status: :missing, input: input, reason: :unknown_capability}
        end
    end
  end

  defp command_token(input) do
    input
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2, trim: true)
    |> List.first()
    |> normalize_command_token()
  end

  defp normalize_command_token(nil), do: {:error, :empty_input}
  defp normalize_command_token(""), do: {:error, :empty_input}

  defp normalize_command_token(token) do
    if String.starts_with?(token, "/") do
      {:ok, token}
    else
      {:error, :not_command_shaped}
    end
  end

  defp preflight(input, %{entry: entry, token: token, canonical: canonical, match: match}) do
    trust = Trust.boundary(entry)
    runnable? = Map.get(entry, :runnable?, false)
    availability = Map.get(entry, :availability, :stub)

    status =
      cond do
        availability != :available -> :blocked
        runnable? != true -> :blocked
        trust.status in [:requires_approval, :unknown] -> :blocked
        true -> :ready
      end

    %{
      status: status,
      input: input,
      reason: blocked_reason(status, availability, runnable?, trust),
      capability: Projection.capability(entry),
      match: %{token: token, canonical: canonical, type: match},
      trust: trust,
      side_effects: Projection.side_effects(entry)
    }
    |> drop_nil_reason()
  end

  defp blocked_reason(:ready, _availability, _runnable?, _trust), do: nil

  defp blocked_reason(:blocked, availability, _runnable?, _trust) when availability != :available,
    do: :unavailable

  defp blocked_reason(:blocked, _availability, false, _trust), do: :not_runnable

  defp blocked_reason(:blocked, _availability, _runnable?, %{status: :requires_approval}),
    do: :trust_requires_approval

  defp blocked_reason(:blocked, _availability, _runnable?, %{status: :unknown}),
    do: :trust_unknown

  defp blocked_reason(:blocked, _availability, _runnable?, _trust), do: :blocked

  defp drop_nil_reason(%{reason: nil} = preflight), do: Map.delete(preflight, :reason)
  defp drop_nil_reason(preflight), do: preflight
end
