defmodule Ourocode.MCP.Transport.StreamableHTTP.SSEBodyParser do
  @moduledoc false

  alias Ourocode.Json

  @spec parse(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse(body) when is_binary(body) do
    body
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.reduce_while({:ok, []}, fn frame, {:ok, acc} ->
      case parse_frame(frame) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp parse_frame(frame) do
    fields =
      frame
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.trim_leading/1)
      |> Enum.reject(&String.starts_with?(&1, ":"))
      |> Enum.reduce(%{}, &put_field/2)

    case fields do
      %{"data" => data_lines} ->
        data = data_lines |> Enum.reverse() |> Enum.join("\n")

        with {:ok, decoded} <- Json.decode(data) do
          {:ok,
           fields
           |> Map.put("data", decoded)
           |> Map.update("event", "message", fn values ->
             values |> List.first() |> to_string()
           end)
           |> Map.update("id", nil, fn values -> values |> List.first() |> to_string() end)}
        end

      _fields ->
        {:ok, nil}
    end
  end

  defp put_field(line, acc) do
    case String.split(line, ":", parts: 2) do
      [key, value] ->
        Map.update(
          acc,
          String.trim(key),
          [String.trim_leading(value)],
          &[String.trim_leading(value) | &1]
        )

      [key] ->
        Map.put_new(acc, String.trim(key), [""])
    end
  end
end
