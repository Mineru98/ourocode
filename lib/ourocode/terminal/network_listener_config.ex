defmodule Ourocode.Terminal.NetworkListenerConfig do
  @moduledoc false

  @core_endpoint_tokens MapSet.new([
                          "core",
                          "input",
                          "input_loop",
                          "interactive",
                          "prompt",
                          "runtime",
                          "terminal",
                          "terminal_ui",
                          "tui",
                          "ui"
                        ])

  @endpoint_requirement_tokens MapSet.new([
                                 "endpoint",
                                 "http",
                                 "https",
                                 "listen",
                                 "listener",
                                 "local_http",
                                 "port",
                                 "server",
                                 "sse",
                                 "websocket",
                                 "web_socket",
                                 "ws",
                                 "wss"
                               ])

  @spec normalize_entries(keyword() | map() | term()) :: [map()]
  def normalize_entries(entries) when is_list(entries) do
    Enum.flat_map(entries, fn {key, value} -> flatten_entry([key], value) end)
  end

  def normalize_entries(entries) when is_map(entries) do
    Enum.flat_map(entries, fn {key, value} -> flatten_entry([key], value) end)
  end

  def normalize_entries(_entries), do: []

  @spec core_endpoint_requirements(keyword() | map() | [map()] | term()) :: [map()]
  def core_endpoint_requirements(entries) do
    entries
    |> normalize_entry_list()
    |> Enum.flat_map(&core_endpoint_requirement/1)
  end

  defp normalize_entry_list(entries) when is_list(entries) do
    if Enum.all?(entries, &match?(%{path: _path, value: _value}, &1)) do
      entries
    else
      normalize_entries(entries)
    end
  end

  defp normalize_entry_list(entries), do: normalize_entries(entries)

  defp flatten_entry(path, value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested_value} ->
      flatten_entry(path ++ [key], nested_value)
    end)
  end

  defp flatten_entry(path, value) when is_list(value) and not is_binary(value) do
    if Keyword.keyword?(value) do
      Enum.flat_map(value, fn {key, nested_value} ->
        flatten_entry(path ++ [key], nested_value)
      end)
    else
      [%{path: path, value: value}]
    end
  end

  defp flatten_entry(path, value), do: [%{path: path, value: value}]

  defp core_endpoint_requirement(%{path: path, value: value}) do
    tokens = path_tokens(path)

    if core_endpoint_path?(tokens) and endpoint_requirement_value?(value) do
      [
        %{
          path: Enum.map_join(path, ".", &to_string/1),
          protocol: endpoint_protocol(tokens, value),
          value_summary: endpoint_value_summary(value)
        }
      ]
    else
      []
    end
  end

  defp path_tokens(path) do
    path
    |> Enum.flat_map(fn segment ->
      segment
      |> to_string()
      |> String.downcase()
      |> String.split([".", "-", "_"], trim: true)
    end)
    |> MapSet.new()
  end

  defp core_endpoint_path?(tokens) do
    intersects?(tokens, @core_endpoint_tokens) and
      intersects?(tokens, @endpoint_requirement_tokens)
  end

  defp endpoint_requirement_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp endpoint_requirement_value?(value) when is_integer(value), do: value > 0
  defp endpoint_requirement_value?(true), do: true
  defp endpoint_requirement_value?(_value), do: false

  defp endpoint_protocol(tokens, value) do
    cond do
      MapSet.member?(tokens, "websocket") or MapSet.member?(tokens, "web_socket") or
        MapSet.member?(tokens, "ws") or endpoint_value_protocol?(value, ["ws://", "wss://"]) ->
        :websocket

      MapSet.member?(tokens, "sse") ->
        :sse

      true ->
        :http
    end
  end

  defp endpoint_value_protocol?(value, prefixes) when is_binary(value) do
    value = String.downcase(String.trim(value))
    Enum.any?(prefixes, &String.starts_with?(value, &1))
  end

  defp endpoint_value_protocol?(_value, _prefixes), do: false

  defp endpoint_value_summary(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp endpoint_value_summary(value), do: inspect(value)

  defp intersects?(left, right) do
    Enum.any?(left, &MapSet.member?(right, &1))
  end
end
