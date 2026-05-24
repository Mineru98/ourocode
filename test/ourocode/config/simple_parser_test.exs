defmodule Ourocode.Config.SimpleParserTest do
  use ExUnit.Case, async: true

  alias Ourocode.Config.SimpleParser

  test "parses JSON config contents" do
    assert SimpleParser.parse(~s({"runtime":{"parallel_child_count":2}}), :json, "config.json") ==
             {:ok, %{"runtime" => %{"parallel_child_count" => 2}}}
  end

  test "parses nested YAML maps, lists, comments, and scalar values" do
    assert SimpleParser.parse(
             """
             runtime:
               parallel_child_count: 4
               enabled: true
               cleanup_policy:
                 stale_cleanup_timeout_ms: 30000
               transports:
                 - stdio
                 - sse
               workers:
                 - id: alpha
                   count: 2
                 - id: beta
                   enabled: false # inline comment
             """,
             :yaml,
             "ourocode.yaml"
           ) ==
             {:ok,
              %{
                "runtime" => %{
                  "parallel_child_count" => 4,
                  "enabled" => true,
                  "cleanup_policy" => %{"stale_cleanup_timeout_ms" => 30000},
                  "transports" => ["stdio", "sse"],
                  "workers" => [
                    %{"id" => "alpha", "count" => 2},
                    %{"id" => "beta", "enabled" => false}
                  ]
                }
              }}
  end

  test "parses TOML sections and scalar lists" do
    assert SimpleParser.parse(
             """
             [runtime]
             parallel_child_count = 3
             transports = ["stdio", "sse"]

             [runtime.cleanup_policy]
             stale_cleanup_timeout_ms = 30000
             allowed_memory_growth_mb = 64
             """,
             :toml,
             "ourocode.toml"
           ) ==
             {:ok,
              %{
                "runtime" => %{
                  "parallel_child_count" => 3,
                  "transports" => ["stdio", "sse"],
                  "cleanup_policy" => %{
                    "stale_cleanup_timeout_ms" => 30000,
                    "allowed_memory_growth_mb" => 64
                  }
                }
              }}
  end

  test "wraps YAML and TOML parse errors with config file context" do
    assert SimpleParser.parse("runtime:\n    too_deep: true\n", :yaml, "bad.yaml") ==
             {:error,
              {:invalid_config_file, "bad.yaml", "unexpected indentation: too_deep: true"}}

    assert SimpleParser.parse(
             "[runtime]\ncleanup = true\n[runtime.cleanup]\nms = 1\n",
             :toml,
             "bad.toml"
           ) ==
             {:error,
              {:invalid_config_file, "bad.toml",
               "cannot assign nested value under scalar key: cleanup"}}
  end
end
