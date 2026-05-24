defmodule Ourocode.Terminal.EventLoopInput do
  @moduledoc """
  Reads and normalizes one raw terminal input item for the event loop.
  """

  alias Ourocode.Terminal.CommandInput

  @type item ::
          :eof
          | {:line, String.t()}
          | {:keyboard, map()}
          | {:error, {:invalid_terminal_input, term()}}

  @spec read(map()) :: item()
  def read(state) when is_map(state) do
    state.read_line.(state.prompt)
    |> normalize()
  end

  @spec normalize(term()) :: item()
  def normalize(:eof), do: :eof
  def normalize(nil), do: :eof

  def normalize(line) when is_binary(line) do
    {:line, CommandInput.trim_terminal_line_ending(line)}
  end

  def normalize(key_input) when is_map(key_input), do: {:keyboard, key_input}
  def normalize({:key, key}), do: {:keyboard, %{key: key}}
  def normalize(other), do: {:error, {:invalid_terminal_input, other}}
end
