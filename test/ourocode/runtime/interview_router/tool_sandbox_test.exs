defmodule Ourocode.Runtime.InterviewRouter.ToolSandboxTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewRouter.ToolSandbox

  test "read returns file contents inside the project root" do
    root = sandbox_dir!()
    File.write!(Path.join(root, "mix.exs"), "defmodule Demo.MixProject do\nend\n")

    assert {"READ mix.exs", body} = ToolSandbox.run(:read, "mix.exs", root)
    assert body =~ "Demo.MixProject"
  end

  test "read rejects unsafe path literals" do
    root = sandbox_dir!()

    assert {"READ ../secret", "rejected: parent escape"} =
             ToolSandbox.run(:read, "../secret", root)

    assert {"READ /etc/passwd", "rejected: absolute path"} =
             ToolSandbox.run(:read, "/etc/passwd", root)

    assert {"READ $HOME/.ssh/id_rsa", "rejected: shell expansion"} =
             ToolSandbox.run(:read, "$HOME/.ssh/id_rsa", root)
  end

  test "read rejects symlink escapes below the project root" do
    root = sandbox_dir!()
    File.ln_s!("/etc", Path.join(root, "escape"))

    assert {"READ escape/passwd", "rejected: symlinked path not allowed in sandbox"} =
             ToolSandbox.run(:read, "escape/passwd", root)
  end

  test "glob lists relative matches and rejects unsafe globs" do
    root = sandbox_dir!()
    File.mkdir_p!(Path.join(root, "lib/demo"))
    File.write!(Path.join(root, "lib/demo/a.ex"), "defmodule A, do: nil")
    File.write!(Path.join(root, "lib/demo/b.ex"), "defmodule B, do: nil")

    assert {"GLOB lib/**/*.ex", body} = ToolSandbox.run(:glob, "lib/**/*.ex", root)
    assert body =~ "lib/demo/a.ex"
    assert body =~ "lib/demo/b.ex"

    assert {"GLOB ../*.ex", "rejected: parent escape"} =
             ToolSandbox.run(:glob, "../*.ex", root)
  end

  test "grep is project-bounded and supports include globs" do
    root = sandbox_dir!()
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo, do: :ok")
    File.write!(Path.join(root, "README.md"), "defmodule should not count")

    assert {"GREP defmodule *.ex", body} = ToolSandbox.run(:grep, "defmodule *.ex", root)
    assert body =~ "lib/demo.ex"
    refute body =~ "README.md"

    assert {"GREP defmodule ../*.ex", "rejected: unsafe glob"} =
             ToolSandbox.run(:grep, "defmodule ../*.ex", root)
  end

  test "unknown tools are rejected without execution" do
    assert {"UNKNOWN \"arg\"", "rejected: unknown tool"} =
             ToolSandbox.run(:shell, "arg", sandbox_dir!())
  end

  defp sandbox_dir! do
    root =
      Path.join(
        System.tmp_dir!(),
        "ourocode-router-sandbox-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
