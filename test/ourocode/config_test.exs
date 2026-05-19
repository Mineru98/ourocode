defmodule Ourocode.ConfigTest do
  use ExUnit.Case, async: false

  alias Ourocode.Config

  setup do
    original_parallel_child_count = Application.get_env(:ourocode, :parallel_child_count)
    original_repeat_count = Application.get_env(:ourocode, :repeat_count)
    original_stream_mailbox_capacity = Application.get_env(:ourocode, :stream_mailbox_capacity)

    original_stream_mailbox_overflow_path =
      Application.get_env(:ourocode, :stream_mailbox_overflow_path)

    original_stream_mailbox_backpressure_threshold =
      Application.get_env(:ourocode, :stream_mailbox_backpressure_threshold)

    original_stream_mailbox_backpressure_behavior =
      Application.get_env(:ourocode, :stream_mailbox_backpressure_behavior)

    original_stream_mailbox_backpressure_delay_ms =
      Application.get_env(:ourocode, :stream_mailbox_backpressure_delay_ms)

    original_allowed_memory_growth_mb = Application.get_env(:ourocode, :allowed_memory_growth_mb)
    original_stale_cleanup_timeout_ms = Application.get_env(:ourocode, :stale_cleanup_timeout_ms)
    original_operation_timeout_ms = Application.get_env(:ourocode, :operation_timeout_ms)

    original_stream_subscription_cleanup_timeout_ms =
      Application.get_env(:ourocode, :stream_subscription_cleanup_timeout_ms)

    original_pane_state_retention_ms = Application.get_env(:ourocode, :pane_state_retention_ms)
    original_cleanup_policy = Application.get_env(:ourocode, :cleanup_policy)

    on_exit(fn ->
      restore_env(:parallel_child_count, original_parallel_child_count)
      restore_env(:repeat_count, original_repeat_count)
      restore_env(:stream_mailbox_capacity, original_stream_mailbox_capacity)
      restore_env(:stream_mailbox_overflow_path, original_stream_mailbox_overflow_path)

      restore_env(
        :stream_mailbox_backpressure_threshold,
        original_stream_mailbox_backpressure_threshold
      )

      restore_env(
        :stream_mailbox_backpressure_behavior,
        original_stream_mailbox_backpressure_behavior
      )

      restore_env(
        :stream_mailbox_backpressure_delay_ms,
        original_stream_mailbox_backpressure_delay_ms
      )

      restore_env(:allowed_memory_growth_mb, original_allowed_memory_growth_mb)
      restore_env(:stale_cleanup_timeout_ms, original_stale_cleanup_timeout_ms)
      restore_env(:operation_timeout_ms, original_operation_timeout_ms)

      restore_env(
        :stream_subscription_cleanup_timeout_ms,
        original_stream_subscription_cleanup_timeout_ms
      )

      restore_env(:pane_state_retention_ms, original_pane_state_retention_ms)
      restore_env(:cleanup_policy, original_cleanup_policy)
    end)
  end

  test "exposes runnable workload defaults" do
    assert Config.default_parallel_child_count() == 3
    assert Config.default_repeat_count() == 1
    assert Config.default_stream_mailbox_capacity() == 1_000
    assert Config.default_stream_mailbox_overflow_path() == :drop
    assert Config.default_stream_mailbox_backpressure_threshold() == 800
    assert Config.default_stream_mailbox_backpressure_behavior() == :notify
    assert Config.default_stream_mailbox_backpressure_delay_ms() == 10
    assert Config.default_allowed_memory_growth_mb() == 64
    assert Config.default_stale_cleanup_timeout_ms() == 30_000
    assert Config.default_operation_timeout_ms() == 120_000
    assert Config.default_stream_subscription_cleanup_timeout_ms() == 10_000
    assert Config.default_pane_state_retention_ms() == 300_000

    assert Config.defaults() == %{
             parallel_child_count: 3,
             repeat_count: 1,
             stream_mailbox_capacity: 1_000,
             stream_mailbox_overflow_path: :drop,
             stream_mailbox_backpressure_threshold: 800,
             stream_mailbox_backpressure_behavior: :notify,
             stream_mailbox_backpressure_delay_ms: 10,
             allowed_memory_growth_mb: 64,
             stale_cleanup_timeout_ms: 30_000,
             operation_timeout_ms: 120_000,
             stream_subscription_cleanup_timeout_ms: 10_000,
             pane_state_retention_ms: 300_000,
             cleanup_policy: %{
               allowed_memory_growth_mb: 64,
               stale_cleanup_timeout_ms: 30_000,
               stream_subscription_cleanup_timeout_ms: 10_000,
               pane_state_retention_ms: 300_000
             }
           }
  end

  test "exposes default cleanup policy with pane state retention" do
    assert Config.default_cleanup_policy() == %{
             allowed_memory_growth_mb: 64,
             stale_cleanup_timeout_ms: 30_000,
             stream_subscription_cleanup_timeout_ms: 10_000,
             pane_state_retention_ms: 300_000
           }

    assert Config.cleanup_policy() == %{
             allowed_memory_growth_mb: 64,
             stale_cleanup_timeout_ms: 30_000,
             stream_subscription_cleanup_timeout_ms: 10_000,
             pane_state_retention_ms: 300_000
           }
  end

  test "defaults are positive integers for runtime loops" do
    assert is_integer(Config.default_parallel_child_count())
    assert Config.default_parallel_child_count() > 0

    assert is_integer(Config.default_repeat_count())
    assert Config.default_repeat_count() > 0

    assert is_integer(Config.default_stream_mailbox_capacity())
    assert Config.default_stream_mailbox_capacity() > 0
    assert Config.default_stream_mailbox_overflow_path() in [:drop, :notify]
    assert is_integer(Config.default_stream_mailbox_backpressure_threshold())
    assert Config.default_stream_mailbox_backpressure_threshold() > 0
    assert Config.default_stream_mailbox_backpressure_behavior() in [:none, :notify, :delay]
    assert is_integer(Config.default_stream_mailbox_backpressure_delay_ms())
    assert Config.default_stream_mailbox_backpressure_delay_ms() > 0

    assert is_integer(Config.default_allowed_memory_growth_mb())
    assert Config.default_allowed_memory_growth_mb() > 0

    assert is_integer(Config.default_stale_cleanup_timeout_ms())
    assert Config.default_stale_cleanup_timeout_ms() > 0

    assert is_integer(Config.default_operation_timeout_ms())
    assert Config.default_operation_timeout_ms() > 0

    assert is_integer(Config.default_stream_subscription_cleanup_timeout_ms())
    assert Config.default_stream_subscription_cleanup_timeout_ms() > 0

    assert is_integer(Config.default_pane_state_retention_ms())
    assert Config.default_pane_state_retention_ms() > 0
  end

  test "defaults read configured positive counts" do
    Application.put_env(:ourocode, :parallel_child_count, 5)
    Application.put_env(:ourocode, :repeat_count, 7)
    Application.put_env(:ourocode, :stream_mailbox_capacity, 33)
    Application.put_env(:ourocode, :stream_mailbox_overflow_path, :notify)
    Application.put_env(:ourocode, :stream_mailbox_backpressure_threshold, 22)
    Application.put_env(:ourocode, :stream_mailbox_backpressure_behavior, :delay)
    Application.put_env(:ourocode, :stream_mailbox_backpressure_delay_ms, 25)
    Application.put_env(:ourocode, :allowed_memory_growth_mb, 128)
    Application.put_env(:ourocode, :stale_cleanup_timeout_ms, 45_000)
    Application.put_env(:ourocode, :operation_timeout_ms, 90_000)
    Application.put_env(:ourocode, :stream_subscription_cleanup_timeout_ms, 12_000)
    Application.put_env(:ourocode, :pane_state_retention_ms, 600_000)

    assert Config.defaults() == %{
             parallel_child_count: 5,
             repeat_count: 7,
             stream_mailbox_capacity: 33,
             stream_mailbox_overflow_path: :notify,
             stream_mailbox_backpressure_threshold: 22,
             stream_mailbox_backpressure_behavior: :delay,
             stream_mailbox_backpressure_delay_ms: 25,
             allowed_memory_growth_mb: 128,
             stale_cleanup_timeout_ms: 45_000,
             operation_timeout_ms: 90_000,
             stream_subscription_cleanup_timeout_ms: 12_000,
             pane_state_retention_ms: 600_000,
             cleanup_policy: %{
               allowed_memory_growth_mb: 128,
               stale_cleanup_timeout_ms: 45_000,
               stream_subscription_cleanup_timeout_ms: 12_000,
               pane_state_retention_ms: 600_000
             }
           }
  end

  test "defaults read configured cleanup policy map" do
    Application.put_env(:ourocode, :cleanup_policy, %{
      allowed_memory_growth_mb: 96,
      stale_cleanup_timeout_ms: 40_000,
      stream_subscription_cleanup_timeout_ms: 11_000,
      pane_state_retention_ms: 450_000
    })

    assert Config.cleanup_policy() == %{
             allowed_memory_growth_mb: 96,
             stale_cleanup_timeout_ms: 40_000,
             stream_subscription_cleanup_timeout_ms: 11_000,
             pane_state_retention_ms: 450_000
           }

    assert Config.defaults().cleanup_policy == Config.cleanup_policy()
  end

  test "validates cleanup policy maps" do
    assert Config.validate_cleanup_policy(%{
             "allowed-memory-growth-mb" => 96,
             "stale-cleanup-timeout-ms" => 40_000,
             "stream-subscription-cleanup-timeout-ms" => 11_000,
             "pane-state-retention-ms" => 450_000
           }) ==
             {:ok,
              %{
                allowed_memory_growth_mb: 96,
                stale_cleanup_timeout_ms: 40_000,
                stream_subscription_cleanup_timeout_ms: 11_000,
                pane_state_retention_ms: 450_000
              }}
  end

  test "parses supported config override inputs" do
    assert Config.parse_overrides([
             "--parallel-child-count",
             "9",
             "--repeat-count=2",
             "--stream-mailbox-capacity=44",
             "--stream-mailbox-overflow-path=notify",
             "--stream-mailbox-backpressure-threshold=30",
             "--stream-mailbox-backpressure-behavior=delay",
             "--stream-mailbox-backpressure-delay-ms=15",
             "--pane-state-retention-ms",
             "600000",
             "--stale-cleanup-timeout-ms=45000",
             "--operation-timeout-ms=90000",
             "--stream-subscription-cleanup-timeout-ms=12000",
             "--allowed-memory-growth-mb=128"
           ]) ==
             {:ok,
              %{
                parallel_child_count: 9,
                repeat_count: 2,
                stream_mailbox_capacity: 44,
                stream_mailbox_overflow_path: :notify,
                stream_mailbox_backpressure_threshold: 30,
                stream_mailbox_backpressure_behavior: :delay,
                stream_mailbox_backpressure_delay_ms: 15,
                pane_state_retention_ms: 600_000,
                stale_cleanup_timeout_ms: 45_000,
                operation_timeout_ms: 90_000,
                stream_subscription_cleanup_timeout_ms: 12_000,
                allowed_memory_growth_mb: 128
              }}
  end

  test "discovers supported project config files in deterministic order" do
    dir = unique_tmp_dir("config-discovery")
    File.mkdir_p!(Path.join(dir, ".ourocode"))
    File.write!(Path.join(dir, "ourocode.toml"), "runtime = true\n")
    File.write!(Path.join(dir, "ourocode.json"), ~s({"runtime":{"parallel-child-count":4}}))
    File.write!(Path.join(dir, ".ourocode/config.yaml"), "plugins:\n  enabled: true\n")
    File.write!(Path.join(dir, "ignored.txt"), "runtime = false\n")

    assert Config.discover_config_files(dir) == [
             Path.join(dir, "ourocode.json"),
             Path.join(dir, "ourocode.toml"),
             Path.join(dir, ".ourocode/config.yaml")
           ]
  after
    cleanup_tmp_dir()
  end

  test "loads JSON YAML and TOML config files into one normalized raw config" do
    dir = unique_tmp_dir("raw-config")
    File.mkdir_p!(Path.join(dir, ".ourocode"))

    File.write!(
      Path.join(dir, "ourocode.json"),
      ~s({"runtime":{"parallel-child-count":4},"mcp":{"transports":["stdio"]}})
    )

    File.write!(
      Path.join(dir, "ourocode.yaml"),
      """
      runtime:
        repeat-count: 2
      wonder-tool:
        enabled: true
      plugins:
        - id: ouroboros-plugin
          source: official
        - id: vim-mode
          source: third-party
      """
    )

    File.write!(
      Path.join(dir, ".ourocode/config.toml"),
      """
      [plugin]
      enabled = true
      sources = ["official", "third_party"]

      [runtime]
      parallel-child-count = 6
      """
    )

    assert {:ok, raw} = Config.load_raw(dir)

    assert raw.root_dir == dir

    assert Enum.map(raw.files, & &1.relative_path) == [
             "ourocode.json",
             "ourocode.yaml",
             ".ourocode/config.toml"
           ]

    assert Enum.map(raw.files, & &1.format) == [:json, :yaml, :toml]

    assert raw.data == %{
             "runtime" => %{"parallel_child_count" => 6, "repeat_count" => 2},
             "mcp" => %{"transports" => ["stdio"]},
             "wonder_tool" => %{"enabled" => true},
             "plugins" => [
               %{"id" => "ouroboros-plugin", "source" => "official"},
               %{"id" => "vim-mode", "source" => "third-party"}
             ],
             "plugin" => %{"enabled" => true, "sources" => ["official", "third_party"]}
           }
  after
    cleanup_tmp_dir()
  end

  test "loader returns documented defaults when no config files exist" do
    dir = unique_tmp_dir("loader-missing-files")

    assert {:ok, config} = Config.load(dir)
    assert config == Config.defaults()
  after
    cleanup_tmp_dir()
  end

  test "loader applies present runtime fields and falls back for omitted optional fields" do
    dir = unique_tmp_dir("loader-partial-runtime")

    File.write!(
      Path.join(dir, "ourocode.json"),
      ~s({"runtime":{"parallel-child-count":5,"cleanup-policy":{"pane-state-retention-ms":900000}}})
    )

    assert {:ok, config} = Config.load(dir)

    assert config.parallel_child_count == 5
    assert config.repeat_count == Config.default_repeat_count()
    assert config.stream_mailbox_capacity == Config.default_stream_mailbox_capacity()
    assert config.operation_timeout_ms == Config.default_operation_timeout_ms()
    assert config.pane_state_retention_ms == 900_000

    assert config.cleanup_policy == %{
             allowed_memory_growth_mb: Config.default_allowed_memory_growth_mb(),
             stale_cleanup_timeout_ms: Config.default_stale_cleanup_timeout_ms(),
             stream_subscription_cleanup_timeout_ms:
               Config.default_stream_subscription_cleanup_timeout_ms(),
             pane_state_retention_ms: 900_000
           }
  after
    cleanup_tmp_dir()
  end

  test "loader merges config files before applying CLI overrides" do
    dir = unique_tmp_dir("loader-cli-precedence")
    File.mkdir_p!(Path.join(dir, ".ourocode"))

    File.write!(
      Path.join(dir, "ourocode.json"),
      ~s({"runtime":{"parallel-child-count":4,"repeat-count":2}})
    )

    File.write!(
      Path.join(dir, ".ourocode/config.toml"),
      """
      [runtime]
      parallel-child-count = 6
      """
    )

    assert {:ok, config} =
             Config.load(dir, [
               "--repeat-count=9",
               "--cleanup-policy.pane-state-retention-ms=800000"
             ])

    assert config.parallel_child_count == 6
    assert config.repeat_count == 9
    assert config.cleanup_policy.pane_state_retention_ms == 800_000

    assert config.cleanup_policy.allowed_memory_growth_mb ==
             Config.default_allowed_memory_growth_mb()
  after
    cleanup_tmp_dir()
  end

  test "loader rejects malformed optional runtime sections with actionable fallback errors" do
    dir = unique_tmp_dir("loader-bad-section")

    File.write!(Path.join(dir, "ourocode.json"), ~s({"runtime":"fast"}))

    assert Config.load(dir) == {:error, {:config_section_must_be_map, "runtime", "fast"}}
  after
    cleanup_tmp_dir()
  end

  test "parses one config file and rejects unsupported or malformed files" do
    dir = unique_tmp_dir("single-config")
    json_path = Path.join(dir, ".ourocode.json")
    text_path = Path.join(dir, "ourocode.txt")
    scalar_path = Path.join(dir, "ourocode.json")
    bad_json_path = Path.join(dir, ".ourocode/config.json")

    File.mkdir_p!(Path.dirname(bad_json_path))
    File.write!(json_path, ~s({"hook-lifecycle":{"visible":true}}))
    File.write!(text_path, "nope")
    File.write!(scalar_path, ~s(["not", "a", "map"]))
    File.write!(bad_json_path, ~s({"missing":))

    assert {:ok, entry} = Config.parse_config_file(json_path, dir)
    assert entry.relative_path == ".ourocode.json"
    assert entry.format == :json
    assert entry.data == %{"hook_lifecycle" => %{"visible" => true}}

    assert {:error, {:unsupported_config_format, ^text_path}} =
             Config.parse_config_file(text_path, dir)

    assert {:error, {:config_file_must_be_map, ^scalar_path}} =
             Config.parse_config_file(scalar_path, dir)

    assert {:error, {:invalid_config_file, ^bad_json_path, _reason}} =
             Config.parse_config_file(bad_json_path, dir)
  after
    cleanup_tmp_dir()
  end

  test "applies cleanup policy override aliases to top-level compatibility fields" do
    assert {:ok, config} =
             Config.defaults_from_args([
               "--cleanup-policy.allowed-memory-growth-mb=192",
               "--cleanup-policy.stale-cleanup-timeout-ms=55000",
               "--cleanup-policy.stream-subscription-cleanup-timeout-ms=15000",
               "--cleanup-policy.pane-state-retention-ms=700000"
             ])

    assert config.allowed_memory_growth_mb == 192
    assert config.stale_cleanup_timeout_ms == 55_000
    assert config.stream_subscription_cleanup_timeout_ms == 15_000
    assert config.pane_state_retention_ms == 700_000

    assert config.cleanup_policy == %{
             allowed_memory_growth_mb: 192,
             stale_cleanup_timeout_ms: 55_000,
             stream_subscription_cleanup_timeout_ms: 15_000,
             pane_state_retention_ms: 700_000
           }
  end

  test "applies cleanup shorthand override aliases" do
    assert {:ok, config} =
             Config.defaults_from_args([
               "--cleanup-allowed-memory-growth-mb=256",
               "--cleanup-stale-cleanup-timeout-ms=65000",
               "--cleanup-stream-subscription-cleanup-timeout-ms=16000",
               "--cleanup-pane-state-retention-ms=800000"
             ])

    assert config.cleanup_policy == %{
             allowed_memory_growth_mb: 256,
             stale_cleanup_timeout_ms: 65_000,
             stream_subscription_cleanup_timeout_ms: 16_000,
             pane_state_retention_ms: 800_000
           }
  end

  test "rejects unsupported and invalid override inputs" do
    assert {:error, message} = Config.parse_overrides(["--unknown-cleanup-ms=1"])
    assert message =~ "unsupported config override arguments"

    assert {:error, message} = Config.parse_overrides(["--pane-state-retention-ms=0"])
    assert message =~ "pane_state_retention_ms must be configured as a positive integer"

    assert {:error, message} =
             Config.parse_overrides(["--cleanup-policy.stale-cleanup-timeout-ms=nope"])

    assert message =~ "invalid config override arguments"

    assert {:error, message} = Config.parse_overrides(["--stream-mailbox-overflow-path=stop"])
    assert message =~ "stream_mailbox_overflow_path must be configured as drop or notify"

    assert {:error, message} =
             Config.parse_overrides(["--stream-mailbox-backpressure-behavior=stop"])

    assert message =~
             "stream_mailbox_backpressure_behavior must be configured as none, notify, or delay"
  end

  test "rejects invalid configured parallel child counts" do
    for invalid <- [0, -1, "5", 1.5, nil] do
      Application.put_env(:ourocode, :parallel_child_count, invalid)

      assert_raise ArgumentError,
                   ~r/parallel_child_count must be configured as a positive integer/,
                   fn -> Config.defaults() end
    end
  end

  test "rejects invalid configured repeat counts" do
    for invalid <- [0, -1, "5", 1.5, nil] do
      Application.put_env(:ourocode, :repeat_count, invalid)

      assert_raise ArgumentError,
                   ~r/repeat_count must be configured as a positive integer/,
                   fn -> Config.defaults() end
    end
  end

  test "rejects invalid configured stream mailbox capacity values" do
    for invalid <- [0, -1, "1000", 1.5, nil] do
      Application.put_env(:ourocode, :stream_mailbox_capacity, invalid)

      assert_raise ArgumentError,
                   ~r/stream_mailbox_capacity must be configured as a positive integer/,
                   fn -> Config.defaults() end
    end
  end

  test "rejects invalid configured stream mailbox overflow paths" do
    for invalid <- [:stop, "raise", 1, nil] do
      Application.put_env(:ourocode, :stream_mailbox_overflow_path, invalid)

      assert_raise ArgumentError,
                   ~r/stream_mailbox_overflow_path must be configured as drop or notify/,
                   fn -> Config.defaults() end
    end
  end

  test "rejects invalid configured stream mailbox backpressure values" do
    for invalid <- [0, -1, "800", 1.5, nil] do
      Application.put_env(:ourocode, :stream_mailbox_backpressure_threshold, invalid)

      assert_raise ArgumentError,
                   ~r/stream_mailbox_backpressure_threshold must be configured as a positive integer/,
                   fn -> Config.defaults() end
    end

    Application.delete_env(:ourocode, :stream_mailbox_backpressure_threshold)

    for invalid <- [0, -1, "10", 1.5, nil] do
      Application.put_env(:ourocode, :stream_mailbox_backpressure_delay_ms, invalid)

      assert_raise ArgumentError,
                   ~r/stream_mailbox_backpressure_delay_ms must be configured as a positive integer/,
                   fn -> Config.defaults() end
    end
  end

  test "rejects invalid configured stream mailbox backpressure behavior" do
    for invalid <- [:drop, "raise", 1, nil] do
      Application.put_env(:ourocode, :stream_mailbox_backpressure_behavior, invalid)

      assert_raise ArgumentError,
                   ~r/stream_mailbox_backpressure_behavior must be configured as none, notify, or delay/,
                   fn -> Config.defaults() end
    end
  end

  test "rejects invalid configured allowed memory growth values" do
    for invalid <- [0, -1, "64", 1.5, nil] do
      Application.put_env(:ourocode, :allowed_memory_growth_mb, invalid)

      assert_raise ArgumentError,
                   ~r/allowed_memory_growth_mb must be configured as a positive integer/,
                   fn -> Config.defaults() end
    end
  end

  test "rejects invalid configured stale cleanup timeout values" do
    for invalid <- [0, -1, "30000", 1.5, nil] do
      Application.put_env(:ourocode, :stale_cleanup_timeout_ms, invalid)

      assert_raise ArgumentError,
                   ~r/stale_cleanup_timeout_ms must be configured as a positive integer/,
                   fn -> Config.defaults() end
    end
  end

  test "rejects invalid configured stream subscription cleanup timeout values" do
    for invalid <- [0, -1, "10000", 1.5, nil] do
      Application.put_env(:ourocode, :stream_subscription_cleanup_timeout_ms, invalid)

      assert_raise ArgumentError,
                   ~r/stream_subscription_cleanup_timeout_ms must be configured as a positive integer/,
                   fn -> Config.defaults() end
    end
  end

  test "rejects invalid configured operation timeout values" do
    for invalid <- [0, -1, "120000", 1.5, nil] do
      Application.put_env(:ourocode, :operation_timeout_ms, invalid)

      assert_raise ArgumentError,
                   ~r/operation_timeout_ms must be configured as a positive integer/,
                   fn -> Config.defaults() end
    end
  end

  test "rejects invalid configured pane state retention values" do
    for invalid <- [0, -1, "300000", 1.5, nil] do
      Application.put_env(:ourocode, :pane_state_retention_ms, invalid)

      assert_raise ArgumentError,
                   ~r/pane_state_retention_ms must be configured as a positive integer/,
                   fn -> Config.defaults() end
    end
  end

  test "rejects invalid cleanup policy maps" do
    invalid_policy_values = [
      allowed_memory_growth_mb: 0,
      stale_cleanup_timeout_ms: -1,
      stream_subscription_cleanup_timeout_ms: "10000",
      pane_state_retention_ms: nil
    ]

    for {key, invalid} <- invalid_policy_values do
      policy =
        Config.default_cleanup_policy()
        |> Map.put(key, invalid)

      assert {:error, message} = Config.validate_cleanup_policy(policy)
      assert message =~ "cleanup_policy.#{key} must be configured as a positive integer"

      Application.put_env(:ourocode, :cleanup_policy, policy)

      assert_raise ArgumentError,
                   ~r/cleanup_policy\./,
                   fn -> Config.defaults() end

      Application.delete_env(:ourocode, :cleanup_policy)
    end
  end

  test "rejects malformed cleanup policy maps" do
    assert Config.validate_cleanup_policy("bad") ==
             {:error, "cleanup_policy must be configured as a map, got: \"bad\""}

    assert {:error, missing_message} =
             Config.default_cleanup_policy()
             |> Map.delete(:pane_state_retention_ms)
             |> Config.validate_cleanup_policy()

    assert missing_message =~ "cleanup_policy is missing required keys"
    assert missing_message =~ "pane_state_retention_ms"

    assert {:error, unknown_message} =
             Config.default_cleanup_policy()
             |> Map.put(:pane_state_limit_ms, 1)
             |> Config.validate_cleanup_policy()

    assert unknown_message =~ "cleanup_policy contains unsupported keys"
    assert unknown_message =~ "pane_state_limit_ms"
  end

  defp restore_env(key, nil), do: Application.delete_env(:ourocode, key)
  defp restore_env(key, value), do: Application.put_env(:ourocode, key, value)

  defp unique_tmp_dir(suffix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-config-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    Process.put(:config_tmp_dirs, [dir | Process.get(:config_tmp_dirs, [])])
    dir
  end

  defp cleanup_tmp_dir do
    Process.get(:config_tmp_dirs, [])
    |> Enum.each(&File.rm_rf!/1)

    Process.delete(:config_tmp_dirs)
  end
end
