defmodule Ourocode.Terminal.VisualArtifactsTest do
  use ExUnit.Case, async: false

  alias Ourocode.Terminal.VisualArtifacts

  test "writes bounded SVG artifacts without stale hero copy" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ourocode-visual-artifacts-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    original_cwd = File.cwd!()

    on_exit(fn ->
      File.cd!(original_cwd)
      File.rm_rf!(tmp)
    end)

    File.cd!(tmp)

    long_line =
      "    >> [1] Define the target user - anchor the PM brief around the primary audience and keep this line wrapped before the terminal edge"

    paths =
      VisualArtifacts.write(%{
        pm_picker: "INTERVIEW\n" <> long_line,
        first_start: "ooo pm <goal>",
        agents: "Guided work",
        cancel: "Interview stopped",
        verify: "checks: 22/22 passed",
        theme: "theme proof",
        theme_light: "theme light\nwhite-toned surface",
        theme_dark: "theme dark\nnear-black surface"
      })

    assert File.exists?(paths.readme_hero)
    assert File.exists?(paths.pm_picker)
    assert File.exists?(paths.theme_light)
    assert File.exists?(paths.theme_dark)

    hero = File.read!(paths.readme_hero)
    light = File.read!(paths.theme_light)
    dark = File.read!(paths.theme_dark)

    refute hero =~ "terminal-native interactive baseline"
    refute hero =~ "ready offline"
    refute hero =~ "Sign in with /login"
    assert hero =~ "Define the target user"
    assert hero =~ "terminal edge"
    assert light =~ ~s(fill="#fafaf9")
    assert light =~ ~s(fill="#f2f2f0")
    refute light =~ ~s(fill="#0a0a0b")
    assert dark =~ ~s(fill="#0a0a0b")
    assert dark =~ ~s(fill="#111111")

    text_nodes = Regex.scan(~r/<text[^>]*>(.*?)<\/text>/, hero, capture: :all_but_first)

    assert Enum.all?(List.flatten(text_nodes), fn text ->
             text
             |> strip_entities()
             |> String.length()
             |> Kernel.<=(92)
           end)
  end

  test "writes artifacts to an explicit directory without touching docs paths" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ourocode-visual-artifacts-custom-#{System.unique_integer([:positive])}"
      )

    hero = Path.join(tmp, "hero.svg")

    on_exit(fn -> File.rm_rf!(tmp) end)

    paths =
      VisualArtifacts.write(
        %{
          pm_picker: "INTERVIEW\n>> [1] Start",
          first_start: "ooo pm <goal>"
        },
        asset_dir: tmp,
        hero_svg: hero
      )

    assert paths.pm_picker == Path.join(tmp, "pm_picker.svg")
    assert paths.first_start == Path.join(tmp, "first_start.svg")
    assert paths.readme_hero == hero
    assert File.exists?(paths.pm_picker)
    assert File.exists?(paths.readme_hero)
    refute String.starts_with?(paths.pm_picker, "docs/")
    refute String.starts_with?(paths.readme_hero, "docs/")
  end

  defp strip_entities(text) do
    text
    |> String.replace("&gt;", ">")
    |> String.replace("&lt;", "<")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
  end
end
