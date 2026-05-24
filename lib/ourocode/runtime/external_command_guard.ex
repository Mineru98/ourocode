defmodule Ourocode.Runtime.ExternalCommandGuard do
  @moduledoc false

  @forbidden_external_commands MapSet.new(["codex", "claude", "claude-code"])
  @shell_commands MapSet.new(["bash", "cmd", "fish", "powershell", "pwsh", "sh", "zsh"])

  @type runner :: (String.t(), [String.t()], term() -> term())

  @spec guarded_runner(runner() | term()) :: runner()
  def guarded_runner(delegate) when is_function(delegate, 3) do
    fn command, args, runner_options ->
      with :ok <- ensure_allowed(command, args) do
        delegate.(command, args, runner_options)
      end
    end
  end

  def guarded_runner(_delegate) do
    fn command, args, _runner_options ->
      with :ok <- ensure_allowed(command, args) do
        {:error, :external_command_runner_not_configured}
      end
    end
  end

  @spec ensure_allowed(String.t(), [String.t()]) :: :ok | {:error, term()}
  def ensure_allowed(command, args) when is_binary(command) and is_list(args) do
    cond do
      forbidden_command?(command) ->
        {:error, {:forbidden_external_command, executable_name(command)}}

      shell_command?(command) and shell_args_include_forbidden_command?(args) ->
        {:error, {:forbidden_external_command, :shell_wrapped_agent_command}}

      true ->
        :ok
    end
  end

  def ensure_allowed(command, args) do
    {:error, {:invalid_external_command_request, command, args}}
  end

  defp forbidden_command?(command) do
    MapSet.member?(@forbidden_external_commands, executable_name(command))
  end

  defp shell_command?(command) do
    MapSet.member?(@shell_commands, executable_name(command))
  end

  defp executable_name(command) do
    command
    |> Path.basename()
    |> String.downcase()
  end

  defp shell_args_include_forbidden_command?(args) do
    args
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(fn arg ->
      Enum.any?(@forbidden_external_commands, &command_token_present?(arg, &1))
    end)
  end

  defp command_token_present?(arg, command) do
    Regex.match?(~r/(^|[^A-Za-z0-9_.-])#{Regex.escape(command)}([^A-Za-z0-9_.-]|$)/, arg)
  end
end
