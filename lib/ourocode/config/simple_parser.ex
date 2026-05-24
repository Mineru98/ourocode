defmodule Ourocode.Config.SimpleParser do
  @moduledoc false

  alias Ourocode.Json

  @spec parse(String.t(), :json | :yaml | :toml, Path.t()) :: {:ok, term()} | {:error, term()}
  def parse(contents, :json, path) do
    case Json.decode(contents) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:invalid_config_file, path, reason}}
    end
  end

  def parse(contents, :yaml, path) do
    parse_yaml(contents)
  rescue
    error -> {:error, {:invalid_config_file, path, Exception.message(error)}}
  catch
    {:invalid_yaml, reason} -> {:error, {:invalid_config_file, path, reason}}
  end

  def parse(contents, :toml, path) do
    parse_toml(contents)
  rescue
    error -> {:error, {:invalid_config_file, path, Exception.message(error)}}
  catch
    {:invalid_toml, reason} -> {:error, {:invalid_config_file, path, reason}}
  end

  defp parse_yaml(contents) do
    lines =
      contents
      |> String.split("\n")
      |> Enum.map(&strip_comment/1)
      |> Enum.reject(&(String.trim(&1) == ""))

    parse_yaml_block(lines, 0)
    |> case do
      {map, []} -> {:ok, map}
      {_map, [line | _rest]} -> throw({:invalid_yaml, "unexpected line: #{String.trim(line)}"})
    end
  end

  defp parse_yaml_block([], _indent), do: {%{}, []}

  defp parse_yaml_block(lines, indent) do
    Enum.reduce_while(lines, {%{}, lines}, fn _line, {acc, remaining} ->
      case remaining do
        [] ->
          {:halt, {acc, []}}

        [line | rest] ->
          line_indent = indentation(line)

          cond do
            line_indent < indent ->
              {:halt, {acc, remaining}}

            line_indent > indent ->
              throw({:invalid_yaml, "unexpected indentation: #{String.trim(line)}"})

            true ->
              {key, value} = parse_yaml_pair(String.trim(line))

              if value == "" do
                {nested, nested_rest} = parse_yaml_nested(rest, indent + 2)
                {:cont, {Map.put(acc, key, nested), nested_rest}}
              else
                {:cont, {Map.put(acc, key, parse_scalar(value)), rest}}
              end
          end
      end
    end)
  end

  defp parse_yaml_nested([line | _rest] = lines, indent) do
    if indentation(line) == indent and line |> String.trim() |> String.starts_with?("- ") do
      parse_yaml_list(lines, indent)
    else
      parse_yaml_block(lines, indent)
    end
  end

  defp parse_yaml_nested([], _indent), do: {%{}, []}

  defp parse_yaml_list(lines, indent), do: parse_yaml_list(lines, indent, [])

  defp parse_yaml_list([], _indent, acc), do: {Enum.reverse(acc), []}

  defp parse_yaml_list([line | rest] = remaining, indent, acc) do
    line_indent = indentation(line)
    trimmed = String.trim(line)

    cond do
      line_indent < indent ->
        {Enum.reverse(acc), remaining}

      line_indent > indent ->
        throw({:invalid_yaml, "unexpected list indentation: #{trimmed}"})

      not String.starts_with?(trimmed, "- ") ->
        {Enum.reverse(acc), remaining}

      true ->
        item_source = trimmed |> String.trim_leading("- ") |> String.trim()
        {item, after_item} = parse_yaml_list_item(item_source, rest, indent)
        parse_yaml_list(after_item, indent, [item | acc])
    end
  end

  defp parse_yaml_list_item("", rest, indent), do: parse_yaml_nested(rest, indent + 2)

  defp parse_yaml_list_item(item_source, rest, indent) do
    item =
      if String.contains?(item_source, ":") do
        {key, value} = parse_yaml_pair(item_source)

        if value == "" do
          {nested, nested_rest} = parse_yaml_nested(rest, indent + 2)
          {%{key => nested}, nested_rest}
        else
          {%{key => parse_scalar(value)}, rest}
        end
      else
        {parse_scalar(item_source), rest}
      end

    merge_yaml_list_item_continuation(item, indent)
  end

  defp merge_yaml_list_item_continuation({item, [line | _rest] = rest}, indent)
       when is_map(item) do
    if indentation(line) > indent do
      {continuation, remaining} = parse_yaml_block(rest, indent + 2)
      {Map.merge(item, continuation), remaining}
    else
      {item, rest}
    end
  end

  defp merge_yaml_list_item_continuation({item, rest}, _indent), do: {item, rest}

  defp parse_yaml_pair(line) do
    case String.split(line, ":", parts: 2) do
      [key, value] when key != "" -> {String.trim(key), String.trim(value)}
      _other -> throw({:invalid_yaml, "expected key: value, got: #{line}"})
    end
  end

  defp parse_toml(contents) do
    contents
    |> String.split("\n")
    |> Enum.map(&strip_comment/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce({%{}, []}, fn line, {acc, section} ->
      trimmed = String.trim(line)

      cond do
        String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]") ->
          section =
            trimmed
            |> String.trim_leading("[")
            |> String.trim_trailing("]")
            |> String.split(".", trim: true)
            |> Enum.map(&String.trim/1)

          if section == [] do
            throw({:invalid_toml, "empty section header"})
          end

          {acc, section}

        true ->
          case String.split(trimmed, "=", parts: 2) do
            [key, value] ->
              path = section ++ [String.trim(key)]
              {put_nested(acc, path, parse_scalar(String.trim(value))), section}

            _other ->
              throw({:invalid_toml, "expected key = value, got: #{trimmed}"})
          end
      end
    end)
    |> elem(0)
    |> then(&{:ok, &1})
  end

  defp put_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_nested(map, [key | rest], value) do
    nested = Map.get(map, key, %{})

    if is_map(nested) do
      Map.put(map, key, put_nested(nested, rest, value))
    else
      throw({:invalid_toml, "cannot assign nested value under scalar key: #{key}"})
    end
  end

  defp strip_comment(line) do
    line
    |> String.split("#", parts: 2)
    |> hd()
  end

  defp indentation(line),
    do: line |> String.length() |> Kernel.-(String.length(String.trim_leading(line)))

  defp parse_scalar(""), do: ""
  defp parse_scalar("true"), do: true
  defp parse_scalar("false"), do: false
  defp parse_scalar("null"), do: nil
  defp parse_scalar("nil"), do: nil

  defp parse_scalar("[" <> _rest = value) do
    if String.ends_with?(value, "]") do
      value
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> split_scalar_list()
      |> Enum.map(&parse_scalar/1)
    else
      value
    end
  end

  defp parse_scalar(value) do
    cond do
      quoted_string?(value) ->
        value
        |> String.slice(1..-2//1)
        |> String.replace("\\\"", "\"")

      match?({_integer, ""}, Integer.parse(value)) ->
        {integer, ""} = Integer.parse(value)
        integer

      match?({_float, ""}, Float.parse(value)) and String.contains?(value, ".") ->
        {float, ""} = Float.parse(value)
        float

      true ->
        value
    end
  end

  defp split_scalar_list(""), do: []

  defp split_scalar_list(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp quoted_string?(value) do
    (String.starts_with?(value, "\"") and String.ends_with?(value, "\"")) or
      (String.starts_with?(value, "'") and String.ends_with?(value, "'"))
  end
end
