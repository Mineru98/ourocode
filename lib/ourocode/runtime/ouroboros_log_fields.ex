defmodule Ourocode.Runtime.OuroborosLogFields do
  @moduledoc """
  Parser for structured `key=value` fragments in Ouroboros log lines.
  """

  @field_re ~r/(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=(?:"([^"]*)"|'([^']*)'|([^\s]+))/

  @spec parse(binary()) :: map()
  def parse(kv) when is_binary(kv) do
    @field_re
    |> Regex.scan(kv)
    |> Map.new(&field_capture/1)
  end

  def parse(_kv), do: %{}

  defp field_capture([_all, key | captures]) do
    value = Enum.find(captures, "", &(&1 != ""))
    {key, value}
  end
end
