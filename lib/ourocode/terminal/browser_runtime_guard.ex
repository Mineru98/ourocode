defmodule Ourocode.Terminal.BrowserRuntimeGuard do
  @moduledoc """
  Startup guard for the terminal-native UI boundary.

  Ourocode's first baseline is a persistent terminal application. This guard
  keeps browser UI runtimes out of the terminal bootstrap contract while still
  allowing HTTP-based MCP transports elsewhere in the runtime.
  """

  @forbidden_otp_apps MapSet.new([
                        :bandit,
                        :cowboy,
                        :desktop,
                        :hound,
                        :phoenix,
                        :phoenix_live_view,
                        :plug,
                        :playwright,
                        :wallaby
                      ])

  @forbidden_process_commands [
    "brave",
    "chrome",
    "chromium",
    "electron",
    "firefox",
    "google-chrome",
    "msedge",
    "playwright",
    "puppeteer",
    "safari",
    "selenium",
    "tauri",
    "webkit",
    "wry"
  ]

  @type report :: %{
          required(:status) => :terminal_only,
          required(:browser_runtime_allowed?) => false,
          required(:forbidden_otp_apps) => [atom()],
          required(:forbidden_process_commands) => [String.t()],
          required(:checked_at_ms) => integer()
        }

  @doc """
  Verifies that terminal startup does not depend on a browser UI runtime.
  """
  @spec verify_startup_boundary() :: {:ok, report()} | {:error, map()}
  def verify_startup_boundary do
    configured_apps = configured_runtime_apps()
    forbidden_apps = Enum.filter(configured_apps, &MapSet.member?(@forbidden_otp_apps, &1))

    if forbidden_apps == [] do
      {:ok, report(forbidden_apps)}
    else
      {:error,
       %{
         status: :unhealthy,
         healthy?: false,
         reason: :browser_runtime_dependency_configured,
         forbidden_otp_apps: forbidden_apps
       }}
    end
  end

  @doc """
  Browser process command names that must not be launched by terminal startup.
  """
  @spec forbidden_process_commands() :: [String.t()]
  def forbidden_process_commands, do: @forbidden_process_commands

  defp configured_runtime_apps do
    :ourocode
    |> Application.spec(:applications)
    |> List.wrap()
  end

  defp report(forbidden_apps) do
    %{
      status: :terminal_only,
      browser_runtime_allowed?: false,
      forbidden_otp_apps: forbidden_apps,
      forbidden_process_commands: @forbidden_process_commands,
      checked_at_ms: System.monotonic_time(:millisecond)
    }
  end
end
