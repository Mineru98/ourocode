defmodule Ourocode.Runtime.SeedArtifactTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.SeedArtifact

  test "extracts seed YAML after the marker" do
    assert {:ok, "seed_id: seed_alpha\nname: Alpha"} =
             SeedArtifact.extract_yaml("""
             Generated successfully.

             --- Seed YAML ---
             seed_id: seed_alpha
             name: Alpha
             """)
  end

  test "ignores text without a seed marker" do
    assert :ignore = SeedArtifact.extract_yaml("No seed here")
  end

  test "resolves seed id from metadata before YAML" do
    yaml = """
    seed_id: seed_from_yaml
    name: Example
    """

    assert "seed_from_meta" = SeedArtifact.seed_id(%{"seed_id" => "seed_from_meta"}, yaml)
  end

  test "resolves seed id from top-level YAML" do
    assert "seed_top" =
             SeedArtifact.seed_id(%{}, """
             seed_id: seed_top
             name: Example
             """)
  end

  test "resolves seed id from nested YAML metadata" do
    assert "seed_nested" =
             SeedArtifact.seed_id(%{}, """
             name: Example
             metadata:
               owner: runtime
               seed_id: seed_nested
             """)
  end

  test "captures seed artifact to the project directory" do
    cwd =
      System.tmp_dir!()
      |> Path.join("ourocode-seed-artifact-#{System.unique_integer([:positive])}")

    File.mkdir_p!(cwd)

    text = """
    Done.

    --- Seed YAML ---
    seed_id: seed_written
    name: Written
    """

    assert {:ok, %{path: path, seed_id: "seed_written"}} = SeedArtifact.capture(text, cwd, %{})
    assert path == Path.join(cwd, "seed_written.yaml")
    assert File.read!(path) == "seed_id: seed_written\nname: Written\n"
  end

  test "ignores marked YAML without a seed id" do
    assert :ignore =
             SeedArtifact.capture(
               """
               --- Seed YAML ---
               name: Missing ID
               """,
               System.tmp_dir!(),
               %{}
             )
  end
end
