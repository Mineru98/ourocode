defmodule Ourocode.MCP.RuntimeEventPath do
  @moduledoc """
  Supported runtime event envelope paths for external ID extraction.

  Runtime transports wrap Codex/CLI payloads in several stable envelope shapes.
  This module owns those traversal paths and atom/string key lookup semantics so
  `RuntimeEventParser` can focus on the ID policy itself.
  """

  @supported_containers [
    [],
    [:msg],
    [:message],
    [:event],
    [:payload],
    [:data],
    [:data, :params],
    [:data, :params, :metadata],
    [:data, :params, :meta],
    [:data, :result],
    [:data, :result, :metadata],
    [:data, :result, :meta],
    [:data, :input],
    [:params],
    [:params, :metadata],
    [:params, :meta],
    [:result],
    [:result, :metadata],
    [:result, :meta],
    [:input],
    [:msg, :payload],
    [:msg, :data],
    [:message, :payload],
    [:message, :data],
    [:event, :payload],
    [:event, :data],
    [:event, :data, :params],
    [:event, :data, :params, :metadata],
    [:event, :data, :params, :meta],
    [:event, :data, :result],
    [:event, :data, :result, :metadata],
    [:event, :data, :result, :meta],
    [:event, :data, :input],
    [:params, :input],
    [:result, :input],
    [:raw_event],
    [:raw_event, :msg],
    [:raw_event, :message],
    [:raw_event, :event],
    [:raw_event, :payload],
    [:raw_event, :data],
    [:raw_event, :data, :params],
    [:raw_event, :data, :params, :metadata],
    [:raw_event, :data, :params, :meta],
    [:raw_event, :data, :result],
    [:raw_event, :data, :result, :metadata],
    [:raw_event, :data, :result, :meta],
    [:raw_event, :data, :input],
    [:raw_event, :params],
    [:raw_event, :params, :metadata],
    [:raw_event, :params, :meta],
    [:raw_event, :result],
    [:raw_event, :result, :metadata],
    [:raw_event, :result, :meta],
    [:raw_event, :event, :payload],
    [:raw_event, :event, :data],
    [:raw_event, :event, :data, :params],
    [:raw_event, :event, :data, :params, :metadata],
    [:raw_event, :event, :data, :params, :meta],
    [:raw_event, :event, :data, :result],
    [:raw_event, :event, :data, :result, :metadata],
    [:raw_event, :event, :data, :result, :meta],
    [:raw_event, :event, :data, :input],
    [:raw_event, :params, :input],
    [:raw_event, :result, :input]
  ]

  @input_containers [
    [:input],
    [:data, :input],
    [:params, :input],
    [:result, :input],
    [:msg, :input],
    [:msg, :payload, :input],
    [:msg, :data, :input],
    [:message, :input],
    [:message, :payload, :input],
    [:message, :data, :input],
    [:event, :input],
    [:event, :payload, :input],
    [:event, :data, :input],
    [:raw_event, :input],
    [:raw_event, :data, :input],
    [:raw_event, :params, :input],
    [:raw_event, :result, :input],
    [:raw_event, :msg, :input],
    [:raw_event, :msg, :payload, :input],
    [:raw_event, :msg, :data, :input],
    [:raw_event, :message, :input],
    [:raw_event, :message, :payload, :input],
    [:raw_event, :message, :data, :input],
    [:raw_event, :event, :input],
    [:raw_event, :event, :payload, :input],
    [:raw_event, :event, :data, :input]
  ]

  @spec supported_containers() :: [[atom()]]
  def supported_containers, do: @supported_containers

  @spec input_containers() :: [[atom()]]
  def input_containers, do: @input_containers

  @spec fetch(map(), [atom()]) :: {:ok, term()} | :error
  def fetch(event, []), do: {:ok, event}

  def fetch(event, [key | rest]) when is_map(event) do
    string_key = Atom.to_string(key)

    case Map.fetch(event, key) do
      {:ok, value} -> fetch(value, rest)
      :error -> fetch_string_path(event, string_key, rest)
    end
  end

  def fetch(_event, _path), do: :error

  defp fetch_string_path(event, string_key, rest) do
    case Map.fetch(event, string_key) do
      {:ok, value} -> fetch(value, rest)
      :error -> :error
    end
  end
end
