defmodule Ourocode.Terminal.CommandThemeCommands do
  @moduledoc """
  Runtime theme switching for the terminal renderer.
  """

  alias Ourocode.Terminal.ScreenStyles

  @actions [:set_theme]
  @env "OUROCODE_THEME"

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec dispatch(:set_theme, map(), map()) :: {:ok, map()} | {:error, term()}
  def dispatch(:set_theme, command_event, state) do
    args = Map.get(command_event, :args, [])
    output = Map.fetch!(state, :output)

    case normalize(args) do
      {:ok, :auto} ->
        System.delete_env(@env)
        render(output, :auto)

      {:ok, theme} when theme in [:light, :dark] ->
        System.put_env(@env, Atom.to_string(theme))
        render(output, theme)

      {:error, reason} ->
        IO.puts(output, "theme: use /theme light, /theme dark, or /theme auto")
        {:error, reason}
    end
  end

  defp normalize([]), do: {:ok, ScreenStyles.theme()}
  defp normalize([""]), do: {:ok, ScreenStyles.theme()}
  defp normalize(["light" | _rest]), do: {:ok, :light}
  defp normalize(["white" | _rest]), do: {:ok, :light}
  defp normalize(["dark" | _rest]), do: {:ok, :dark}
  defp normalize(["auto" | _rest]), do: {:ok, :auto}
  defp normalize(["system" | _rest]), do: {:ok, :auto}
  defp normalize([_other | _rest]), do: {:error, :invalid_theme}

  defp render(output, :auto) do
    active = ScreenStyles.theme()
    IO.puts(output, theme_text(:auto, active))
    {:ok, %{theme: :auto, active_theme: active}}
  end

  defp render(output, theme) do
    IO.puts(output, theme_text(theme, theme))
    {:ok, %{theme: theme, active_theme: theme}}
  end

  defp theme_text(theme, active) do
    """
    theme workspace · Theme
    Status · #{active} active
    theme: #{theme}
    Modes · /theme light | /theme dark | /theme auto
    Current · #{theme}
    Light · white canvas with soft panel surfaces
    Dark · near-black canvas with deep panel surfaces
    Next · Use /theme light or /theme dark; the next redraw repaints the full screen.
    """
    |> String.trim_trailing()
  end
end
