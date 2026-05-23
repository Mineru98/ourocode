defmodule Ourocode.Json do
  @moduledoc """
  Small JSON codec used by transport tests and bootstrap code.

  The MVP keeps transport code dependency-free so synthetic MCP transport tests
  can run before plugin/runtime dependencies are introduced.
  """

  @type json_value ::
          nil
          | boolean()
          | number()
          | String.t()
          | [json_value()]
          | %{optional(String.t() | atom()) => json_value()}

  @spec encode!(json_value()) :: iodata()
  def encode!(value) do
    encode_value(value)
  end

  @spec decode(String.t()) :: {:ok, json_value()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    with {:ok, value, rest} <- parse_value(skip_ws(binary)),
         "" <- skip_ws(rest) do
      {:ok, value}
    else
      {:error, reason} -> {:error, reason}
      rest when is_binary(rest) -> {:error, {:trailing_data, rest}}
      other -> {:error, other}
    end
  end

  @spec decode!(String.t()) :: json_value()
  def decode!(binary) do
    case decode(binary) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "invalid JSON: #{inspect(reason)}"
    end
  end

  defp encode_value(nil), do: "null"
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_float(value), do: Float.to_string(value)
  defp encode_value(value) when is_binary(value), do: encode_string(value)

  defp encode_value(value) when is_list(value) do
    ["[", value |> Enum.map(&encode_value/1) |> Enum.intersperse(","), "]"]
  end

  defp encode_value(value) when is_map(value) do
    members =
      value
      |> Enum.map(fn {key, member_value} ->
        [encode_string(to_string(key)), ":", encode_value(member_value)]
      end)
      |> Enum.intersperse(",")

    ["{", members, "}"]
  end

  defp encode_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    ["\"", escaped, "\""]
  end

  defp parse_value(""), do: {:error, :unexpected_end}
  defp parse_value("null" <> rest), do: {:ok, nil, rest}
  defp parse_value("true" <> rest), do: {:ok, true, rest}
  defp parse_value("false" <> rest), do: {:ok, false, rest}
  defp parse_value("\"" <> rest), do: parse_string(rest, [])
  defp parse_value("[" <> rest), do: parse_array(skip_ws(rest), [])
  defp parse_value("{" <> rest), do: parse_object(skip_ws(rest), %{})

  defp parse_value(binary) do
    parse_number(binary)
  end

  defp parse_string("\"" <> rest, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp parse_string("\\\"" <> rest, acc), do: parse_string(rest, [?\" | acc])
  defp parse_string("\\\\" <> rest, acc), do: parse_string(rest, [?\\ | acc])
  defp parse_string("\\/" <> rest, acc), do: parse_string(rest, [?/ | acc])
  defp parse_string("\\b" <> rest, acc), do: parse_string(rest, [?\b | acc])
  defp parse_string("\\f" <> rest, acc), do: parse_string(rest, [?\f | acc])
  defp parse_string("\\n" <> rest, acc), do: parse_string(rest, [?\n | acc])
  defp parse_string("\\r" <> rest, acc), do: parse_string(rest, [?\r | acc])
  defp parse_string("\\t" <> rest, acc), do: parse_string(rest, [?\t | acc])
  defp parse_string("", _acc), do: {:error, :unterminated_string}

  defp parse_string(<<char::utf8, rest::binary>>, acc) do
    parse_string(rest, [<<char::utf8>> | acc])
  end

  defp parse_array("]" <> rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_array(binary, acc) do
    with {:ok, value, rest} <- parse_value(skip_ws(binary)) do
      case skip_ws(rest) do
        "," <> next -> parse_array(skip_ws(next), [value | acc])
        "]" <> next -> {:ok, Enum.reverse([value | acc]), next}
        other -> {:error, {:expected_array_separator, other}}
      end
    end
  end

  defp parse_object("}" <> rest, acc), do: {:ok, acc, rest}

  defp parse_object("\"" <> rest, acc) do
    with {:ok, key, after_key} <- parse_string(rest, []),
         ":" <> after_colon <- skip_ws(after_key),
         {:ok, value, after_value} <- parse_value(skip_ws(after_colon)) do
      case skip_ws(after_value) do
        "," <> next -> parse_object(skip_ws(next), Map.put(acc, key, value))
        "}" <> next -> {:ok, Map.put(acc, key, value), next}
        other -> {:error, {:expected_object_separator, other}}
      end
    else
      other -> {:error, {:invalid_object, other}}
    end
  end

  defp parse_object(other, _acc), do: {:error, {:expected_object_key, other}}

  defp parse_number(binary) do
    case Regex.run(~r/\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/, binary) do
      [number] ->
        rest = binary_part(binary, byte_size(number), byte_size(binary) - byte_size(number))

        if String.contains?(number, [".", "e", "E"]) do
          {value, ""} = Float.parse(number)
          {:ok, value, rest}
        else
          {value, ""} = Integer.parse(number)
          {:ok, value, rest}
        end

      nil ->
        {:error, {:invalid_value, binary}}
    end
  end

  defp skip_ws(<<char, rest::binary>>) when char in [?\s, ?\n, ?\r, ?\t], do: skip_ws(rest)
  defp skip_ws(binary), do: binary
end
