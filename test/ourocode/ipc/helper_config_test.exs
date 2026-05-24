defmodule Ourocode.IPC.HelperConfigTest do
  use ExUnit.Case, async: false

  alias Ourocode.IPC.HelperConfig

  setup do
    original = Application.get_env(:ourocode, :rust_helpers)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ourocode, :rust_helpers)
        value -> Application.put_env(:ourocode, :rust_helpers, value)
      end
    end)
  end

  test "normalizes inline command configs" do
    assert HelperConfig.resolve(%{command: "/bin/helper", args: ["scan"]}) ==
             {:ok, %{name: :inline, command: "/bin/helper", args: ["scan"], version: nil}}
  end

  test "resolves atom and string helper keys from application config" do
    Application.put_env(:ourocode, :rust_helpers, %{
      "formatter" => %{"command" => "/bin/formatter", "args" => []},
      scanner: %{path: "/bin/scanner", args: ["--json"], version: "v1"}
    })

    assert HelperConfig.resolve(%{helper: :scanner}) ==
             {:ok, %{name: :scanner, command: "/bin/scanner", args: ["--json"], version: "v1"}}

    assert HelperConfig.resolve(%{helper: :formatter}) ==
             {:ok, %{name: :formatter, command: "/bin/formatter", args: [], version: nil}}
  end

  test "returns structured errors for missing or malformed helper configs" do
    Application.put_env(:ourocode, :rust_helpers, %{
      bad_command: %{path: " "},
      bad_args: %{path: "/bin/helper", args: [:not_binary]},
      bad_version: %{path: "/bin/helper", version: 1}
    })

    assert HelperConfig.resolve(%{helper: :missing}) ==
             {:error, {:missing_helper_config, :missing}}

    assert HelperConfig.resolve(%{helper: :bad_command}) ==
             {:error, {:invalid_helper_command, :bad_command}}

    assert HelperConfig.resolve(%{helper: :bad_args}) ==
             {:error, {:invalid_helper_args, :bad_args}}

    assert HelperConfig.resolve(%{helper: :bad_version}) ==
             {:error, {:invalid_helper_version, :bad_version}}
  end

  test "normalizes binary command shorthand and rejects invalid shapes" do
    assert HelperConfig.normalize("/bin/helper", :scanner) ==
             {:ok, %{name: :scanner, command: "/bin/helper", args: [], version: nil}}

    assert HelperConfig.normalize([command: "/bin/helper"], :scanner) ==
             {:error, {:invalid_helper_config, :scanner}}
  end
end
