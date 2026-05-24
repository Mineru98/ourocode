defmodule Ourocode.Plugin.ChecksumTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.Checksum

  test "compute is stable regardless of filesystem listing order" do
    plugin_path = tmp_dir!("stable")
    File.mkdir_p!(Path.join(plugin_path, "nested"))
    File.write!(Path.join(plugin_path, "b.txt"), "second")
    File.write!(Path.join(plugin_path, "nested/a.txt"), "first")

    assert {:ok, checksum_a} = Checksum.compute(plugin_path)
    assert {:ok, checksum_b} = Checksum.compute(plugin_path)
    assert checksum_a == checksum_b
    assert String.length(checksum_a) == 64
  end

  test "compute includes relative paths in the digest" do
    left = tmp_dir!("left")
    right = tmp_dir!("right")

    File.write!(Path.join(left, "same.txt"), "content")
    File.mkdir_p!(Path.join(right, "nested"))
    File.write!(Path.join(right, "nested/same.txt"), "content")

    assert {:ok, left_checksum} = Checksum.compute(left)
    assert {:ok, right_checksum} = Checksum.compute(right)
    refute left_checksum == right_checksum
  end

  test "compute reports unavailable directories" do
    assert Checksum.compute(Path.join(System.tmp_dir!(), "missing-#{System.unique_integer()}")) ==
             {:error, :plugin_checksum_unavailable}
  end

  defp tmp_dir!(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-plugin-checksum-#{name}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
