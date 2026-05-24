defmodule Ourocode.MCP.ChildSessionIdentifier do
  @moduledoc """
  Normalizes explicit child-session identifiers from runtime payloads.

  Runtime transports use several aliases for the same child/session identity.
  This module keeps those alias and pane-key rules separate from event-level
  extraction and fallback handling.
  """

  alias Ourocode.MCP.ChildSessionPayloads

  @child_pane_prefix "child-session:"

  @type source ::
          :childID
          | :childId
          | :child_id
          | :child_session_id
          | :agent_session_id
          | :opencode_child_id
          | :pane_key

  @id_sources [
    {:childID, ["childID", :childID]},
    {:childId, ["childId", :childId]},
    {:child_id, ["child_id", :child_id]},
    {:child_session_id,
     [
       "child_session_id",
       :child_session_id,
       "childSessionID",
       :childSessionID,
       "childSessionId",
       :childSessionId
     ]},
    {:agent_session_id,
     [
       "agent_session_id",
       :agent_session_id,
       "agentSessionID",
       :agentSessionID,
       "agentSessionId",
       :agentSessionId
     ]},
    {:opencode_child_id, ["opencode_childID", :opencode_childID]},
    {:pane_key, ["pane_key", :pane_key, "paneKey", :paneKey]}
  ]

  @spec explicit_child_id(map()) :: {String.t(), source()} | nil
  def explicit_child_id(payload) when is_map(payload) do
    @id_sources
    |> Enum.find_value(fn {source, keys} ->
      payload
      |> ChildSessionPayloads.any(keys)
      |> normalize_explicit_child_id(source)
      |> case do
        nil -> nil
        child_id -> {child_id, source}
      end
    end)
  end

  def explicit_child_id(_payload), do: nil

  @spec malformed_child_id_payload?(term()) :: boolean()
  def malformed_child_id_payload?(payload) when is_map(payload) do
    Enum.any?(@id_sources, fn {source, keys} ->
      Enum.any?(keys, fn key ->
        Map.has_key?(payload, key) and
          normalize_explicit_child_id(Map.get(payload, key), source) == nil
      end)
    end)
  end

  def malformed_child_id_payload?(_payload), do: false

  @spec pane_key(String.t()) :: String.t()
  def pane_key(child_id), do: @child_pane_prefix <> child_id

  @spec normalize_child_id(term()) :: String.t() | nil
  def normalize_child_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_child_id(_value), do: nil

  defp normalize_explicit_child_id(value, :pane_key), do: normalize_pane_key(value)
  defp normalize_explicit_child_id(value, _source), do: normalize_child_id(value)

  defp normalize_pane_key(value) when is_binary(value) do
    value
    |> normalize_child_id()
    |> case do
      @child_pane_prefix <> child_id -> normalize_child_id(child_id)
      _other -> nil
    end
  end

  defp normalize_pane_key(_value), do: nil
end
