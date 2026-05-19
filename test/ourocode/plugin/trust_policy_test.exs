defmodule Ourocode.Plugin.TrustPolicyTest do
  use ExUnit.Case, async: false

  alias Ourocode.Plugin.TrustPolicy

  setup do
    original_approvals = Application.get_env(:ourocode, :plugin_trusted_approvals)

    on_exit(fn ->
      restore_env(:plugin_trusted_approvals, original_approvals)
    end)
  end

  test "classifies the official ouroboros-plugin identity as trusted" do
    manifest = %{
      "capabilities" => [],
      "plugin" => %{
        "id" => "ouroboros-plugin",
        "trust_tier" => "official"
      }
    }

    assert %{
             trust_tier: "official",
             trust_classification: "official_trusted",
             plugin_id: "ouroboros-plugin"
           } = TrustPolicy.classify(manifest)

    assert {:ok,
            %{
              trust_tier: "official",
              trust_classification: "official_trusted",
              plugin_id: "ouroboros-plugin"
            }} =
             TrustPolicy.validate(manifest, "/plugins/official", "abc123")
  end

  test "classifies unknown plugin identifiers as untrusted" do
    manifest = %{
      "capabilities" => [],
      "plugin" => %{
        "id" => "unknown-plugin",
        "trust_tier" => "official"
      }
    }

    assert %{
             trust_tier: "official",
             trust_classification: "untrusted",
             plugin_id: "unknown-plugin"
           } = TrustPolicy.classify(manifest)

    assert {:error, :untrusted_plugin_identity} =
             TrustPolicy.validate(manifest, "/plugins/unknown", "abc123")
  end

  test "classifies spoofed ouroboros-plugin identifiers as untrusted" do
    for spoofed_id <- ["ouroboros-plugin-dev", "com.example.ouroboros-plugin", "Ouroboros Plugin"] do
      manifest = %{
        "capabilities" => [],
        "plugin_id" => spoofed_id,
        "trust_tier" => "official"
      }

      assert %{
               trust_tier: "official",
               trust_classification: "untrusted",
               plugin_id: ^spoofed_id
             } = TrustPolicy.classify(manifest)

      assert {:error, :untrusted_plugin_identity} =
               TrustPolicy.validate(manifest, "/plugins/#{spoofed_id}", "abc123")
    end
  end

  test "rejects community-code plugins without a trusted approval record" do
    assert {:error, :missing_community_plugin_trust_approval} =
             TrustPolicy.validate(
               %{"capabilities" => [], "trust_tier" => "community_code"},
               "/plugins/community",
               "abc123"
             )
  end

  test "accepts community-code plugins with an explicit matching trusted approval record" do
    plugin_path = "/plugins/community"
    checksum = String.duplicate("a", 64)

    approval = %{
      plugin_path: plugin_path,
      checksum: checksum,
      trust_tier: "community_code",
      approved: true
    }

    assert {:ok,
            %{
              trust_tier: "community_code",
              trust_approval: ^approval
            }} =
             TrustPolicy.validate(
               %{"capabilities" => [], "trust_tier" => "community_code"},
               plugin_path,
               checksum,
               trusted_approvals: [approval]
             )
  end

  test "rejects community-code plugins when the approval checksum does not match" do
    plugin_path = "/plugins/community"

    approval = %{
      "plugin_path" => plugin_path,
      "checksum" => String.duplicate("0", 64),
      "trust_tier" => "community_code",
      "approved" => true
    }

    assert {:error, :missing_community_plugin_trust_approval} =
             TrustPolicy.validate(
               %{"capabilities" => [], "trust_tier" => "community_code"},
               plugin_path,
               String.duplicate("a", 64),
               trusted_approvals: [approval]
             )
  end

  test "rejects community-code plugins when matching trust approval has been revoked" do
    plugin_path = "/plugins/community"
    checksum = String.duplicate("c", 64)

    prior_approval = %{
      plugin_path: plugin_path,
      checksum: checksum,
      trust_tier: "community_code",
      approved: true
    }

    revocation = %{
      "plugin_path" => plugin_path,
      "checksum" => checksum,
      "trust_tier" => "community_code",
      "approved" => true,
      "revoked" => true
    }

    assert {:error, :revoked_community_plugin_trust_approval} =
             TrustPolicy.validate(
               %{"capabilities" => [], "trust_tier" => "community_code"},
               plugin_path,
               checksum,
               trusted_approvals: [prior_approval, revocation]
             )
  end

  test "reads trusted approvals from application config" do
    plugin_path = "/plugins/community"
    checksum = String.duplicate("b", 64)

    Application.put_env(:ourocode, :plugin_trusted_approvals, [
      %{
        "plugin_path" => plugin_path,
        "checksum" => checksum,
        "trust_tier" => "community-code",
        "approved" => true
      }
    ])

    assert {:ok, %{trust_tier: "community-code"}} =
             TrustPolicy.validate(
               %{"capabilities" => [], "trust_tier" => "community-code"},
               plugin_path,
               checksum
             )
  end

  defp restore_env(key, nil), do: Application.delete_env(:ourocode, key)
  defp restore_env(key, value), do: Application.put_env(:ourocode, key, value)
end
