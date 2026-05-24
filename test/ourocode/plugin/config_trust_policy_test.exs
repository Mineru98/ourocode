defmodule Ourocode.Plugin.ConfigTrustPolicyTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigTrustPolicy

  test "parse defaults official source to official tier" do
    assert ConfigTrustPolicy.parse(%{}, "official", 0) ==
             {:ok,
              {%{"tier" => "official", "requires_explicit_approval" => false}, "absent_defaulted"}}
  end

  test "parse defaults non-official source to community code tier" do
    assert ConfigTrustPolicy.parse(%{}, "third_party", 1) ==
             {:ok,
              {%{"tier" => "community_code", "requires_explicit_approval" => true},
               "absent_defaulted"}}
  end

  test "parse preserves configured policy fields and accepts trust_tier alias" do
    plugin = %{
      "trust_policy" => %{
        "trust_tier" => "community-code",
        "approval_id" => "approval-vim-mode"
      }
    }

    assert ConfigTrustPolicy.parse(plugin, "third_party", 2) ==
             {:ok,
              {%{
                 "trust_tier" => "community-code",
                 "tier" => "community-code",
                 "approval_id" => "approval-vim-mode",
                 "requires_explicit_approval" => true
               }, "configured"}}
  end

  test "parse rejects invalid trust policy shapes" do
    assert ConfigTrustPolicy.parse(%{"trust_policy" => []}, "third_party", 3) ==
             {:error,
              {:invalid_plugin_config_schema, "plugins[3].trust_policy must be an object"}}

    assert ConfigTrustPolicy.parse(%{"trust_policy" => %{"tier" => 10}}, "third_party", 3) ==
             {:error,
              {:invalid_plugin_config_schema, "plugins[3].trust_policy.tier must be a string"}}

    assert ConfigTrustPolicy.parse(
             %{"trust_policy" => %{"tier" => "partner"}},
             "third_party",
             3
           ) ==
             {:error,
              {:invalid_plugin_config_schema, "plugins[3].trust_policy.tier is unsupported"}}
  end

  test "validate_official_identity enforces canonical official plugin boundary" do
    assert ConfigTrustPolicy.validate_official_identity(
             "ouroboros-plugin",
             "official",
             %{"tier" => "official"},
             0
           ) == :ok

    assert ConfigTrustPolicy.validate_official_identity(
             "ouroboros-plugin-dev",
             "official",
             %{"tier" => "official"},
             0
           ) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[0] official plugin must be ouroboros-plugin, got ouroboros-plugin-dev"}}

    assert ConfigTrustPolicy.validate_official_identity(
             "ouroboros-plugin",
             "third_party",
             %{"tier" => "community_code"},
             0
           ) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[0] ouroboros-plugin must use source official"}}
  end

  test "evaluate returns string-keyed trust classification" do
    assert ConfigTrustPolicy.evaluate(
             "vim-mode",
             %{"tier" => "community_code", "requires_explicit_approval" => true},
             0
           ) ==
             {:ok,
              %{
                "plugin_id" => "vim-mode",
                "trust_tier" => "community_code",
                "trust_classification" => "community_code",
                "requires_explicit_approval" => true
              }}
  end
end
