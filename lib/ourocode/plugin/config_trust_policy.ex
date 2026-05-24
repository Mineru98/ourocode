defmodule Ourocode.Plugin.ConfigTrustPolicy do
  @moduledoc """
  Parses and evaluates plugin trust policy configuration.
  """

  @official_plugin_id "ouroboros-plugin"
  @valid_trust_tiers MapSet.new(["official", "community_code", "community-code", "untrusted"])

  @type schema_error :: {:error, {:invalid_plugin_config_schema, String.t()}}

  @spec parse(map(), String.t(), non_neg_integer()) ::
          {:ok, {map(), String.t()}} | schema_error()
  def parse(plugin, source, index) when is_map(plugin) and is_binary(source) do
    default_tier = default_tier(source)

    {policy, trust_policy_state} =
      case Map.fetch(plugin, "trust_policy") do
        {:ok, configured_policy} -> {configured_policy, "configured"}
        :error -> {%{"tier" => default_tier}, "absent_defaulted"}
      end

    normalize(policy, default_tier, trust_policy_state, index)
  end

  @spec validate_official_identity(String.t(), String.t(), map(), non_neg_integer()) ::
          :ok | schema_error()
  def validate_official_identity(
        @official_plugin_id,
        "official",
        %{"tier" => "official"},
        _index
      ) do
    :ok
  end

  def validate_official_identity(@official_plugin_id, "official", trust_policy, index) do
    schema_error(
      "plugins[#{index}] official plugin must use trust tier official, got #{trust_policy["tier"]}"
    )
  end

  def validate_official_identity(id, "official", _trust_policy, index) do
    schema_error("plugins[#{index}] official plugin must be #{@official_plugin_id}, got #{id}")
  end

  def validate_official_identity(@official_plugin_id, _source, _trust_policy, index) do
    schema_error("plugins[#{index}] #{@official_plugin_id} must use source official")
  end

  def validate_official_identity(_id, _source, _trust_policy, _index), do: :ok

  @spec evaluate(String.t(), map(), non_neg_integer()) :: {:ok, map()}
  def evaluate(id, %{"tier" => tier} = trust_policy, _index) when is_binary(id) do
    manifest = %{
      "plugin" => %{
        "id" => id,
        "trust_tier" => tier
      }
    }

    trust_result =
      manifest
      |> Ourocode.Plugin.TrustPolicy.classify()
      |> atom_keys_to_strings()
      |> Map.put("requires_explicit_approval", trust_policy["requires_explicit_approval"])

    {:ok, trust_result}
  end

  defp default_tier("official"), do: "official"
  defp default_tier(_source), do: "community_code"

  defp normalize(policy, default_tier, trust_policy_state, index) when is_map(policy) do
    tier = Map.get(policy, "tier", Map.get(policy, "trust_tier", default_tier))

    cond do
      not is_binary(tier) ->
        schema_error("plugins[#{index}].trust_policy.tier must be a string")

      not MapSet.member?(@valid_trust_tiers, tier) ->
        schema_error("plugins[#{index}].trust_policy.tier is unsupported")

      true ->
        {:ok,
         {policy
          |> Map.put("tier", tier)
          |> Map.put_new("requires_explicit_approval", tier != "official"), trust_policy_state}}
    end
  end

  defp normalize(_policy, _default_tier, _trust_policy_state, index) do
    schema_error("plugins[#{index}].trust_policy must be an object")
  end

  defp atom_keys_to_strings(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp schema_error(message), do: {:error, {:invalid_plugin_config_schema, message}}
end
