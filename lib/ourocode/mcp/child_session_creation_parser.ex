defmodule Ourocode.MCP.ChildSessionCreationParser do
  @moduledoc """
  Extracts child agent/session creation IDs from normalized MCP lifecycle events.

  Transports preserve runtime payloads in different lifecycle fields
  (`notification`, `result`, `params`, `external_ids`). This parser keeps child
  ID detection transport-neutral so pane mapping and journal writers can share
  one interpretation of supported runtime payload shapes.
  """

  alias Ourocode.MCP.ChildSessionFallback
  alias Ourocode.MCP.ChildSessionIdentifier
  alias Ourocode.MCP.ChildSessionPayloads

  @type id_source ::
          :childID
          | :childId
          | :child_id
          | :child_session_id
          | :agent_session_id
          | :opencode_child_id
          | :pane_key
          | {:fallback, atom()}

  @type extraction :: %{
          required(:child_id) => String.t(),
          required(:pane_key) => String.t(),
          required(:source) => id_source(),
          required(:payload_path) => atom()
        }

  @type unresolved :: %{
          required(:status) => :unresolved,
          required(:reason) => :missing_fallback_runtime_metadata,
          required(:parent_call_id) => String.t(),
          required(:checked_sources) => list(atom())
        }

  @doc """
  Extracts a runtime `childID`/`child_id` from supported event payloads.

  When a child/session creation or stream event does not include a runtime
  child ID, returns a stable fallback derived from trusted runtime IDs. The
  fallback keeps panes and journals recoverable without claiming the runtime
  emitted an actual `childID`.
  """
  @spec extract(map() | struct()) :: {:ok, extraction()} | {:unresolved, unresolved()} | :ignore
  def extract(%_{} = event), do: event |> Map.from_struct() |> extract()

  def extract(event) when is_map(event) do
    case explicit_extraction(event) do
      {:ok, extraction} -> {:ok, extraction}
      :ignore -> ChildSessionFallback.extract(event)
    end
  end

  def extract(_event), do: :ignore

  @doc """
  Convenience wrapper when callers only need the child ID string.
  """
  @spec extract_child_id(map() | struct()) :: {:ok, String.t()} | :ignore
  def extract_child_id(event) do
    case extract(event) do
      {:ok, %{child_id: child_id}} -> {:ok, child_id}
      {:unresolved, _unresolved} -> :ignore
      :ignore -> :ignore
    end
  end

  @doc """
  Convenience wrapper when callers only need the stable dashboard pane key.
  """
  @spec extract_pane_key(map() | struct()) :: {:ok, String.t()} | :ignore
  def extract_pane_key(event) do
    case extract(event) do
      {:ok, %{pane_key: pane_key}} -> {:ok, pane_key}
      {:unresolved, _unresolved} -> :ignore
      :ignore -> :ignore
    end
  end

  defp candidate_payloads(event), do: ChildSessionPayloads.candidates(event)

  defp explicit_extraction(event) do
    event
    |> candidate_payloads()
    |> Enum.find_value(:ignore, fn {payload_path, payload} ->
      case explicit_child_id(payload) do
        nil ->
          nil

        {child_id, source} ->
          {:ok, extraction(child_id, source, payload_path)}
      end
    end)
  end

  defp explicit_child_id(payload) when is_map(payload) do
    ChildSessionIdentifier.explicit_child_id(payload)
  end

  defp explicit_child_id(_payload), do: nil

  defp extraction(child_id, source, payload_path) do
    %{
      child_id: child_id,
      pane_key: pane_key(child_id),
      source: source,
      payload_path: payload_path
    }
  end

  defp pane_key(child_id), do: ChildSessionIdentifier.pane_key(child_id)
end
