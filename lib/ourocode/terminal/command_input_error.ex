defmodule Ourocode.Terminal.CommandInputError do
  @moduledoc """
  User-facing text formatting for terminal command input errors.
  """

  @spec format(term()) :: String.t()
  def format(reason) when is_binary(reason), do: reason

  def format({:unknown_command, command, []}) do
    "unknown command #{command}"
  end

  def format({:unknown_command, command, suggestions}) when is_list(suggestions) do
    "unknown command #{command}. did you mean #{Enum.join(suggestions, ", ")}?"
  end

  def format(reason) do
    inspect(reason, limit: 20, printable_limit: 200)
  end
end
