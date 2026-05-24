defmodule Ourocode.MCP.ChildSessionFallback do
  @moduledoc """
  Derives stable fallback child-session IDs when runtime child IDs are absent.

  Explicit child ID parsing stays in `ChildSessionCreationParser`. This module
  owns fallback eligibility, runtime ID precedence, malformed-child guards, and
  unresolved diagnostics.
  """

  alias Ourocode.MCP.ChildSessionIdentifier
  alias Ourocode.MCP.ChildSessionPayloads
  alias Ourocode.MCP.ChildSessionRuntimeIds

  @doc """
  Returns fallback extraction data, unresolved metadata, or `:ignore`.
  """
  @spec extract(map()) ::
          {:ok,
           %{
             required(:child_id) => String.t(),
             required(:pane_key) => String.t(),
             required(:source) => {:fallback, atom()},
             required(:payload_path) => :fallback_runtime_id
           }}
          | {:unresolved, map()}
          | :ignore
  def extract(event) when is_map(event) do
    if malformed_child_id_present?(event) do
      :ignore
    else
      fallback_extraction(event)
    end
  end

  def extract(_event), do: :ignore

  @doc """
  Returns the runtime ID sources checked for fallback IDs, in precedence order.
  """
  @spec runtime_id_sources() :: [atom()]
  def runtime_id_sources, do: ChildSessionRuntimeIds.sources()

  defp malformed_child_id_present?(event) do
    event
    |> candidate_payloads()
    |> Enum.any?(fn {_path, payload} -> malformed_child_id_payload?(payload) end)
  end

  defp malformed_child_id_payload?(payload) when is_map(payload) do
    ChildSessionIdentifier.malformed_child_id_payload?(payload)
  end

  defp malformed_child_id_payload?(_payload), do: false

  defp fallback_extraction(event) do
    with true <- fallback_eligible?(event),
         {:ok, _parent_call_id} <- required_runtime_id(event, :parent_call_id),
         {source, value} <- ChildSessionRuntimeIds.preferred(event) do
      child_id = "fallback:" <> Atom.to_string(source) <> ":" <> value

      {:ok,
       %{
         child_id: child_id,
         pane_key: ChildSessionIdentifier.pane_key(child_id),
         source: {:fallback, source},
         payload_path: :fallback_runtime_id
       }}
    else
      nil ->
        {:unresolved,
         %{
           status: :unresolved,
           reason: :missing_fallback_runtime_metadata,
           parent_call_id: ChildSessionRuntimeIds.value(event, :parent_call_id),
           checked_sources: runtime_id_sources()
         }}

      _ ->
        :ignore
    end
  end

  defp fallback_eligible?(event) do
    stream_event?(event) or child_session_creation_event?(event)
  end

  defp stream_event?(event) do
    event_type(event) == :parent_call_event and
      event
      |> candidate_payloads()
      |> Enum.any?(fn {_path, payload} -> stream_payload?(payload) end)
  end

  defp stream_payload?(payload) when is_map(payload) do
    payload
    |> any([
      "seq",
      :seq,
      "event_seq",
      :event_seq,
      "token",
      :token,
      "delta",
      :delta,
      "content",
      :content
    ])
    |> present?()
  end

  defp stream_payload?(_payload), do: false

  defp child_session_creation_event?(event) do
    event_type(event) == :parent_call_started and
      event
      |> field(:method)
      |> child_session_creation_method?()
  end

  defp child_session_creation_method?(method) when is_binary(method) do
    normalized =
      method
      |> String.trim()
      |> String.downcase()

    normalized == "session/create" or String.ends_with?(normalized, "/session/create")
  end

  defp child_session_creation_method?(_method), do: false

  defp required_runtime_id(event, key) do
    case ChildSessionRuntimeIds.value(event, key) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp event_type(event) do
    value = any(event, [:type, "type"])

    cond do
      is_atom(value) -> value
      is_binary(value) -> known_event_type(value)
      true -> nil
    end
  end

  defp known_event_type(value) do
    case String.trim(value) do
      "parent_call_started" -> :parent_call_started
      "parent_call_result" -> :parent_call_result
      "parent_call_event" -> :parent_call_event
      _other -> nil
    end
  end

  defp candidate_payloads(event), do: ChildSessionPayloads.candidates(event)
  defp field(map, key), do: ChildSessionPayloads.field(map, key)
  defp any(map, keys), do: ChildSessionPayloads.any(map, keys)

  defp present?(value), do: value not in [nil, ""]
end
