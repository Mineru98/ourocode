defmodule Ourocode.Terminal.CommandThemeCommandsTest do
  use ExUnit.Case, async: false

  alias Ourocode.Terminal.CommandHandler
  alias Ourocode.Terminal.CommandInput

  @env "OUROCODE_THEME"

  setup do
    original = System.get_env(@env)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(@env)
        value -> System.put_env(@env, value)
      end
    end)

    {:ok, output} = StringIO.open("")
    %{output: output}
  end

  test "sets light and dark themes from slash command", %{output: output} do
    assert {:ok, %{theme: :light, active_theme: :light}} =
             CommandHandler.handle(CommandInput.command_event("/theme light"), state(output))

    assert System.get_env(@env) == "light"

    assert {:ok, %{theme: :dark, active_theme: :dark}} =
             CommandHandler.handle(CommandInput.command_event("/theme dark"), state(output))

    assert System.get_env(@env) == "dark"

    {_input, text} = StringIO.contents(output)
    assert text =~ "theme: light"
    assert text =~ "theme: dark"
    assert text =~ "theme workspace · Theme"
    assert text =~ "Modes · /theme light | /theme dark | /theme auto"
    assert text =~ "Next · Use /theme light or /theme dark"
  end

  test "auto theme clears explicit override", %{output: output} do
    System.put_env(@env, "light")

    assert {:ok, %{theme: :auto}} =
             CommandHandler.handle(CommandInput.command_event("/theme auto"), state(output))

    assert System.get_env(@env) == nil

    {_input, text} = StringIO.contents(output)
    assert text =~ "theme: auto"
    assert text =~ "Status ·"
  end

  test "invalid theme reports allowed modes", %{output: output} do
    assert {:error, :invalid_theme} =
             CommandHandler.handle(CommandInput.command_event("/theme sepia"), state(output))

    {_input, text} = StringIO.contents(output)
    assert text =~ "/theme light"
    assert text =~ "/theme dark"
    assert text =~ "/theme auto"
  end

  defp state(output), do: %{output: output, startup_result: %{commands: %{entries: [], aliases: %{}}}}
end
