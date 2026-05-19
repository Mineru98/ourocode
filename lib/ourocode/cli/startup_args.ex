defmodule Ourocode.CLI.StartupArgs do
  @moduledoc """
  Parses launch-time arguments for the terminal application.

  Startup arguments configure the terminal bootstrap boundary. Runtime config
  overrides and natural-language task text are handed off to the existing
  config/task parsers after startup-only flags are removed.
  """

  @default_project_dir "/Users/jaegyu.lee/Project/ourocode"
  @project_dir_flags MapSet.new(["--project-dir", "--project"])
  @smoke_test_flags MapSet.new(["--smoke-test", "--smoke"])
  @config_flags_with_value MapSet.new([
                             "--parallel-child-count",
                             "--repeat-count",
                             "--allowed-memory-growth-mb",
                             "--stale-cleanup-timeout-ms",
                             "--operation-timeout-ms",
                             "--stream-subscription-cleanup-timeout-ms",
                             "--pane-state-retention-ms",
                             "--cleanup-allowed-memory-growth-mb",
                             "--cleanup-stale-cleanup-timeout-ms",
                             "--cleanup-stream-subscription-cleanup-timeout-ms",
                             "--cleanup-pane-state-retention-ms",
                             "--cleanup-policy.allowed-memory-growth-mb",
                             "--cleanup-policy.stale-cleanup-timeout-ms",
                             "--cleanup-policy.stream-subscription-cleanup-timeout-ms",
                             "--cleanup-policy.pane-state-retention-ms"
                           ])

  @type t :: %{
          required(:project_dir) => String.t(),
          required(:smoke_test?) => boolean(),
          required(:config_args) => [String.t()],
          required(:task_request) => Ourocode.TaskRequest.t() | nil
        }

  @doc """
  Parses CLI startup arguments.

  Supported startup flags:

    * `--project-dir PATH`
    * `--project-dir=PATH`
    * `--project PATH`
    * `--project=PATH`
    * `--smoke-test`
    * `--smoke`

  All remaining leading config flags stay available to `Ourocode.Config`; the
  first non-flag token begins the optional natural-language task.
  """
  @spec parse([String.t()], keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def parse(args, options \\ [])

  def parse(args, options) when is_list(args) do
    with {:ok, {project_dir, smoke_test?, remaining_args}} <-
           extract_startup_args(args, default_project_dir()),
         {:ok, parsed_args} <- Ourocode.TaskRequest.parse_cli_args(remaining_args, options) do
      {:ok,
       %{
         project_dir: project_dir,
         smoke_test?: smoke_test?,
         config_args: parsed_args.config_args,
         task_request: parsed_args.task_request
       }}
    end
  end

  def parse(_args, _options), do: {:error, "CLI args must be a list"}

  @doc """
  Returns the default implementation project directory for the launcher.
  """
  @spec default_project_dir() :: String.t()
  def default_project_dir, do: @default_project_dir

  defp extract_startup_args(args, project_dir),
    do: extract_startup_args(args, project_dir, false, [])

  defp extract_startup_args([], project_dir, smoke_test?, kept_args) do
    {:ok, {project_dir, smoke_test?, Enum.reverse(kept_args)}}
  end

  defp extract_startup_args(["--" | task_args], project_dir, smoke_test?, kept_args) do
    {:ok, {project_dir, smoke_test?, Enum.reverse(kept_args) ++ ["--" | task_args]}}
  end

  defp extract_startup_args([arg | rest], project_dir, smoke_test?, kept_args)
       when is_binary(arg) do
    cond do
      project_dir_assignment?(arg) ->
        [flag, value] = String.split(arg, "=", parts: 2)
        consume_project_dir(flag, value, rest, smoke_test?, kept_args)

      MapSet.member?(@project_dir_flags, arg) ->
        case rest do
          [value | tail] when is_binary(value) ->
            consume_project_dir(arg, value, tail, smoke_test?, kept_args)

          [] ->
            {:error, "missing value for startup argument: #{arg}"}

          [value | _tail] ->
            {:error, "startup argument #{arg} expects a string value, got: #{inspect(value)}"}
        end

      MapSet.member?(@smoke_test_flags, arg) ->
        extract_startup_args(rest, project_dir, true, kept_args)

      MapSet.member?(@config_flags_with_value, arg) ->
        preserve_config_value(arg, rest, project_dir, smoke_test?, kept_args)

      String.starts_with?(arg, "--") ->
        extract_startup_args(rest, project_dir, smoke_test?, [arg | kept_args])

      true ->
        {:ok, {project_dir, smoke_test?, Enum.reverse(kept_args) ++ [arg | rest]}}
    end
  end

  defp extract_startup_args([arg | _rest], _project_dir, _smoke_test?, _kept_args) do
    {:error, "CLI args must be strings, got: #{inspect(arg)}"}
  end

  defp project_dir_assignment?(arg) do
    case String.split(arg, "=", parts: 2) do
      [flag, _value] -> MapSet.member?(@project_dir_flags, flag)
      _other -> false
    end
  end

  defp consume_project_dir(flag, value, rest, smoke_test?, kept_args) do
    value = String.trim(value)

    if value == "" or String.starts_with?(value, "--") do
      {:error, "missing value for startup argument: #{flag}"}
    else
      extract_startup_args(rest, Path.expand(value), smoke_test?, kept_args)
    end
  end

  defp preserve_config_value(arg, [value | rest], project_dir, smoke_test?, kept_args)
       when is_binary(value) do
    extract_startup_args(rest, project_dir, smoke_test?, [value, arg | kept_args])
  end

  defp preserve_config_value(arg, [], _project_dir, _smoke_test?, _kept_args) do
    {:error, "missing value for config override argument: #{arg}"}
  end

  defp preserve_config_value(arg, [value | _rest], _project_dir, _smoke_test?, _kept_args) do
    {:error, "config override argument #{arg} expects a string value, got: #{inspect(value)}"}
  end
end
