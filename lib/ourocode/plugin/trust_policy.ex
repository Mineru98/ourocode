defmodule Ourocode.Plugin.TrustPolicy do
  @moduledoc """
  Enforces plugin trust-tier and identity loading rules.

  Official trust is reserved for the exact canonical `ouroboros-plugin`
  identity. Unknown official claims fail closed.

  Community-code plugins are user-trusted code strategies. They may be loaded
  only when an explicit approval record matches the expanded plugin path and
  computed checksum for the current plugin bytes.
  """

  @app :ourocode
  @official_plugin_id "ouroboros-plugin"
  @community_code_tiers MapSet.new(["community_code", "community-code"])

  @type validation_error ::
          :missing_community_plugin_trust_approval
          | :revoked_community_plugin_trust_approval
          | :invalid_plugin_trust_approvals
          | :untrusted_plugin_identity

  @type trust_result :: %{
          required(:trust_tier) => String.t(),
          required(:trust_classification) => String.t(),
          optional(:plugin_id) => String.t(),
          optional(:trust_approval) => map()
        }

  @doc """
  Validates trust policy for a parsed capability manifest.

  Options:

    * `:trusted_approvals` - approval records. Defaults to
      `Application.get_env(:ourocode, :plugin_trusted_approvals, [])`.

  A community-code approval record must contain:

    * `plugin_path` matching the expanded plugin path
    * `checksum` matching the computed plugin checksum
    * `trust_tier` matching `community_code` or `community-code`
    * `approved` set to `true`

  A matching approval record with `revoked` set to `true` rejects the plugin,
  even if an older matching approval record is still present.
  """
  @spec validate(map(), Path.t(), String.t(), keyword()) ::
          {:ok, trust_result()} | {:error, validation_error()}
  def validate(capability_manifest, plugin_path, checksum, opts \\ [])
      when is_map(capability_manifest) and is_binary(plugin_path) and is_binary(checksum) and
             is_list(opts) do
    classification = classify(capability_manifest)

    case classification do
      %{trust_classification: "official_trusted"} = result ->
        {:ok, result}

      %{trust_classification: "community_code", trust_tier: trust_tier} = result ->
        validate_community_code_approval(plugin_path, checksum, trust_tier, result, opts)

      %{trust_classification: "untrusted"} ->
        {:error, :untrusted_plugin_identity}
    end
  end

  @doc """
  Classifies plugin trust from the capability manifest identity.

  Official trust is granted only to the exact canonical ouroboros-plugin
  identity. Other official claims fail closed as untrusted, while community-code
  plugins are classified for explicit approval validation.
  """
  @spec classify(map()) :: trust_result()
  def classify(capability_manifest) when is_map(capability_manifest) do
    trust_tier = trust_tier(capability_manifest)
    plugin_id = plugin_id(capability_manifest)

    cond do
      official?(trust_tier, plugin_id) ->
        %{
          trust_tier: "official",
          trust_classification: "official_trusted",
          plugin_id: @official_plugin_id
        }

      community_code?(trust_tier) ->
        %{
          trust_tier: trust_tier,
          trust_classification: "community_code"
        }
        |> maybe_put_plugin_id(plugin_id)

      true ->
        %{
          trust_tier: trust_tier,
          trust_classification: "untrusted"
        }
        |> maybe_put_plugin_id(plugin_id)
    end
  end

  defp validate_community_code_approval(plugin_path, checksum, trust_tier, result, opts) do
    with {:ok, approvals} <- trusted_approvals(opts),
         {:ok, approval} <- find_matching_approval(approvals, plugin_path, checksum, trust_tier) do
      {:ok, Map.put(result, :trust_approval, approval)}
    end
  end

  defp trusted_approvals(opts) do
    approvals =
      Keyword.get(
        opts,
        :trusted_approvals,
        Application.get_env(@app, :plugin_trusted_approvals, [])
      )

    if is_list(approvals) and Enum.all?(approvals, &is_map/1) do
      {:ok, approvals}
    else
      {:error, :invalid_plugin_trust_approvals}
    end
  end

  defp find_matching_approval(approvals, plugin_path, checksum, trust_tier) do
    case Enum.find(approvals, &revocation_matches?(&1, plugin_path, checksum, trust_tier)) do
      nil ->
        case Enum.find(approvals, &approval_matches?(&1, plugin_path, checksum, trust_tier)) do
          nil -> {:error, :missing_community_plugin_trust_approval}
          approval -> {:ok, approval}
        end

      _revocation ->
        {:error, :revoked_community_plugin_trust_approval}
    end
  end

  defp approval_matches?(approval, plugin_path, checksum, trust_tier) do
    approval_value(approval, :approved) == true and
      approval_value(approval, :revoked) != true and
      approval_identity_matches?(approval, plugin_path, checksum, trust_tier)
  end

  defp revocation_matches?(approval, plugin_path, checksum, trust_tier) do
    approval_value(approval, :revoked) == true and
      approval_identity_matches?(approval, plugin_path, checksum, trust_tier)
  end

  defp approval_identity_matches?(approval, plugin_path, checksum, trust_tier) do
    approval_value(approval, :plugin_path) == plugin_path and
      approval_value(approval, :checksum) == checksum and
      community_code?(approval_value(approval, :trust_tier)) and
      normalize_tier(approval_value(approval, :trust_tier)) == normalize_tier(trust_tier)
  end

  defp trust_tier(%{"trust_tier" => trust_tier}) when is_binary(trust_tier), do: trust_tier

  defp trust_tier(%{"plugin" => %{"trust_tier" => trust_tier}}) when is_binary(trust_tier) do
    trust_tier
  end

  defp trust_tier(_manifest), do: "unknown"

  defp plugin_id(%{"plugin" => %{"id" => plugin_id}}) when is_binary(plugin_id), do: plugin_id
  defp plugin_id(%{"plugin" => %{"name" => plugin_id}}) when is_binary(plugin_id), do: plugin_id
  defp plugin_id(%{"plugin_id" => plugin_id}) when is_binary(plugin_id), do: plugin_id
  defp plugin_id(%{"id" => plugin_id}) when is_binary(plugin_id), do: plugin_id
  defp plugin_id(%{"name" => plugin_id}) when is_binary(plugin_id), do: plugin_id
  defp plugin_id(_manifest), do: nil

  defp official?(trust_tier, plugin_id) when is_binary(trust_tier) and is_binary(plugin_id) do
    normalize_tier(trust_tier) == "official" and plugin_id == @official_plugin_id
  end

  defp official?(_trust_tier, _plugin_id), do: false

  defp community_code?(trust_tier) when is_binary(trust_tier) do
    MapSet.member?(@community_code_tiers, normalize_tier(trust_tier))
  end

  defp community_code?(_trust_tier), do: false

  defp normalize_tier(tier) when is_binary(tier), do: String.downcase(tier)

  defp maybe_put_plugin_id(result, plugin_id) when is_binary(plugin_id) do
    Map.put(result, :plugin_id, plugin_id)
  end

  defp maybe_put_plugin_id(result, _plugin_id), do: result

  defp approval_value(approval, key) do
    case Map.fetch(approval, key) do
      {:ok, value} -> value
      :error -> Map.get(approval, Atom.to_string(key))
    end
  end
end
