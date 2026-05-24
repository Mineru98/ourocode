defmodule Ourocode.Command.CapabilityPreflight do
  @moduledoc """
  Read-only capability resolution and preflight projection.

  This module is intentionally narrow: it resolves command-shaped input against
  the already-loaded command registry and projects what would run without
  executing, trusting, installing, or mutating plugin state.
  """

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
    trust = trust_boundary(entry)
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
      capability: capability(entry),
      match: %{token: token, canonical: canonical, type: match},
      trust: trust,
      side_effects: side_effects(entry)
    }
    |> drop_nil_reason()
  end

  defp capability(entry) do
    %{
      id: entry.id,
      name: entry.name,
      slash: entry.slash,
      aliases: entry.aliases,
      source: entry.source,
      source_id: entry.source_id,
      category: entry.category,
      summary: entry.summary,
      args: entry.args,
      run_spec: entry.run_spec,
      metadata: %{
        plugin_id: get_in(entry, [:metadata, :plugin_id]),
        plugin_source: get_in(entry, [:metadata, :plugin_source]),
        namespace_owner: get_in(entry, [:metadata, :namespace_owner]),
        command_namespace: get_in(entry, [:metadata, :command_namespace])
      }
    }
  end

  defp trust_boundary(%{source: :plugin, metadata: metadata}) do
    trust_policy = Map.get(metadata, :trust_policy, %{}) || %{}
    trust_evaluation = Map.get(metadata, :trust_evaluation, %{}) || %{}

    status =
      cond do
        trusted_evaluation?(trust_evaluation) -> :trusted
        official_without_explicit_approval?(trust_policy) -> :trusted
        explicit_approval_required?(trust_policy) -> :requires_approval
        true -> :unknown
      end

    %{
      source: :plugin,
      status: status,
      plugin_id: Map.get(metadata, :plugin_id),
      policy_state: Map.get(metadata, :trust_policy_state),
      policy: trust_policy,
      evaluation: trust_evaluation
    }
  end

  defp trust_boundary(_entry) do
    %{source: :registry, status: :not_applicable}
  end

  defp trusted_evaluation?(%{"trusted" => true}), do: true
  defp trusted_evaluation?(%{trusted: true}), do: true
  defp trusted_evaluation?(_evaluation), do: false

  defp official_without_explicit_approval?(policy) do
    policy_value(policy, "tier") == "official" and not explicit_approval_required?(policy)
  end

  defp explicit_approval_required?(policy) do
    policy_value(policy, "requires_explicit_approval") == true
  end

  defp policy_value(policy, key) do
    Map.get(policy, key, Map.get(policy, String.to_atom(key)))
  end

  defp side_effects(entry) do
    %{
      execution: :none,
      discovery: :read_only,
      expected_outputs: expected_outputs(entry),
      risk_class: risk_class(entry)
    }
  end

  defp expected_outputs(entry) do
    entry
    |> get_in([:metadata, :expected_outputs])
    |> List.wrap()
  end

  defp risk_class(%{source: :plugin, metadata: metadata}) do
    metadata
    |> Map.get(:trust_evaluation, %{})
    |> evaluation_value("trust_classification")
    |> case do
      nil -> :unknown
      value -> value
    end
  end

  defp risk_class(_entry), do: :not_applicable

  defp evaluation_value(evaluation, key) when is_map(evaluation) do
    Map.get(evaluation, key, Map.get(evaluation, String.to_atom(key)))
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
