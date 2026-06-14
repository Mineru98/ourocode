defmodule Ourocode.Model.CliTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model.Cli

  test "known CLI specs exclude slow agent CLIs" do
    assert Cli.specs() == %{gemini: "gemini"}
  end

  test "gemini args ignore the system prompt" do
    refute "--append-system-prompt" in Cli.args(:gemini, "hi", "You are ourocode.")
  end

  test "retries a run that fails before emitting any output" do
    tmp_dir = tmp_dir!()
    marker = Path.join(tmp_dir, "ran-once")
    gemini_path = Path.join(tmp_dir, "gemini")

    # Fails silently on the first launch, echoes the prompt on the second.
    File.write!(gemini_path, """
    #!/bin/sh
    if [ -f "#{marker}" ]; then printf '%s' "$2"; else touch "#{marker}"; exit 1; fi
    """)

    File.chmod!(gemini_path, 0o755)

    assert {:ok, "hello"} =
             Cli.stream(
               :gemini,
               "hello",
               [which: fn "gemini" -> gemini_path end, retry_base_delay_ms: 1],
               fn _chunk -> :ok end
             )

    assert File.exists?(marker)
  end

  test "does not retry once output has reached the renderer" do
    tmp_dir = tmp_dir!()
    count = Path.join(tmp_dir, "count")
    gemini_path = Path.join(tmp_dir, "gemini")

    File.write!(gemini_path, """
    #!/bin/sh
    echo run >> "#{count}"
    printf 'partial '
    exit 1
    """)

    File.chmod!(gemini_path, 0o755)

    assert {:error, {:exit, 1}} =
             Cli.stream(
               :gemini,
               "hello",
               [which: fn "gemini" -> gemini_path end, retry_base_delay_ms: 1],
               fn _chunk -> :ok end
             )

    assert File.read!(count) == "run\n"
  end

  test "a persistent silent failure surfaces after the retry budget" do
    tmp_dir = tmp_dir!()
    count = Path.join(tmp_dir, "count")
    gemini_path = Path.join(tmp_dir, "gemini")

    File.write!(gemini_path, """
    #!/bin/sh
    echo run >> "#{count}"
    exit 7
    """)

    File.chmod!(gemini_path, 0o755)

    assert {:error, {:exit, 7}} =
             Cli.stream(
               :gemini,
               "hello",
               [which: fn "gemini" -> gemini_path end, retry_base_delay_ms: 1],
               fn _chunk -> :ok end
             )

    assert File.read!(count) == "run\nrun\nrun\n"
  end

  defp tmp_dir! do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ourocode-cli-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    tmp_dir
  end
end
