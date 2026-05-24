defmodule Ourocode.Command.CapabilityPreflight.Trust do
  @moduledoc """
  Trust-boundary projection for command capability preflight.
  """

  @spec boundary(map()) :: map()
  def boundary(%{source: :plugin, metadata: metadata}) do
    trust_policy = Map.get(metadata, :trust_policy, %{}) || %{}
    trust_evaluation = Map.get(metadata, :trust_evaluation, %{}) || %{}

    %{
      source: :plugin,
      status: status(trust_policy, trust_evaluation),
      plugin_id: Map.get(metadata, :plugin_id),
      policy_state: Map.get(metadata, :trust_policy_state),
      policy: trust_policy,
      evaluation: trust_evaluation
    }
  end

  def boundary(_entry) do
    %{source: :registry, status: :not_applicable}
  end

  defp status(trust_policy, trust_evaluation) do
    cond do
      trusted_evaluation?(trust_evaluation) -> :trusted
      official_without_explicit_approval?(trust_policy) -> :trusted
      explicit_approval_required?(trust_policy) -> :requires_approval
      true -> :unknown
    end
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
end
