defmodule Ourocode.Dashboard.ChildSessionPaneRuntimeIdentity do
  @moduledoc """
  Extracts and stabilizes runtime identity for child session panes.

  Event conversion owns pane map construction. This module owns the runtime ID
  precedence rules, external ID normalization, and fallback pane reuse rules.
  """

  alias Ourocode.Dashboard.ChildSessionIdentity
  alias Ourocode.Dashboard.ChildSessionMetadata
  alias Ourocode.MCP.ChildSessionCreationParser
  alias Ourocode.MCP.RuntimeEventParser
  alias Ourocode.MCP.Transport.StdoutJsonlParser

  @fallback_metadata_precedence [:primary, :stdout_jsonl, :runtime_event]

  @doc """
  Extracts a child runtime ID and the source used to derive it.
  """
  @spec extract(map()) ::
          {:ok, {String.t(), :runtime_child_id | :pane_key | {:fallback, atom()}}} | :error
  def extract(event) when is_map(event) do
    event =
      event
      |> Map.put(:external_ids, external_ids_map(event))
      |> Map.put(:fallback_runtime_metadata, fallback_runtime_metadata(event))

    case ChildSessionCreationParser.extract(event) do
      {:ok, %{child_id: child_id, source: {:fallback, source}}} ->
        {:ok, {child_id, {:fallback, source}}}

      {:ok, %{child_id: child_id, source: :pane_key}} ->
        {:ok, {child_id, :pane_key}}

      {:ok, %{child_id: child_id}} ->
        {:ok, {child_id, :runtime_child_id}}

      {:unresolved, _reason} ->
        :error

      :ignore ->
        :error
    end
  end

  def extract(_event), do: :error

  @doc """
  Builds pane external IDs for the extracted child runtime ID source.
  """
  @spec external_ids(map(), String.t(), :runtime_child_id | :pane_key | {:fallback, atom()}) ::
          map()
  def external_ids(event, child_id, :runtime_child_id) do
    event
    |> external_ids_map()
    |> Map.put_new("childID", child_id)
  end

  def external_ids(event, child_id, :pane_key) do
    event
    |> external_ids_map()
    |> Map.put_new("pane_key", ChildSessionIdentity.pane_id(child_id))
    |> Map.put_new("child_id", child_id)
  end

  def external_ids(event, child_id, {:fallback, source}) do
    event
    |> external_ids_map()
    |> Map.put_new("fallback_child_id", child_id)
    |> Map.put_new("fallback_child_id_source", Atom.to_string(source))
    |> Map.put_new("child_id", child_id)
  end

  @doc """
  Reuses an existing fallback pane identity when runtime metadata proves the
  incoming fallback belongs to the same child session.
  """
  @spec stabilize_fallback_child_id([map()], map()) :: map()
  def stabilize_fallback_child_id(existing_panes, pane) when is_list(existing_panes) do
    if fallback_pane?(pane) do
      case Enum.find(existing_panes, &same_fallback_runtime?(&1, pane)) do
        nil -> pane
        existing -> reuse_fallback_child_id(pane, existing)
      end
    else
      pane
    end
  end

  def stabilize_fallback_child_id(_existing_panes, pane), do: pane

  @spec fallback_pane?(map()) :: boolean()
  def fallback_pane?(%{external_ids: external_ids}) when is_map(external_ids),
    do: Map.has_key?(external_ids, "fallback_child_id")

  def fallback_pane?(_pane), do: false

  defp external_ids_map(event) do
    event
    |> runtime_event_external_ids()
    |> Map.merge(valid_runtime_external_ids(stdout_jsonl_external_ids(event)))
    |> Map.merge(valid_runtime_external_ids(primary_external_ids(event)))
  end

  defp primary_external_ids(event) do
    case Map.get(event, :external_ids) || Map.get(event, "external_ids") do
      external_ids when is_map(external_ids) -> external_ids
      _value -> %{}
    end
  end

  defp runtime_event_external_ids(event) do
    event
    |> RuntimeEventParser.extract_external_ids()
    |> valid_runtime_external_ids()
  end

  defp fallback_runtime_metadata(event) do
    candidates = %{
      primary: valid_runtime_external_ids(primary_external_ids(event)),
      stdout_jsonl: valid_runtime_external_ids(stdout_jsonl_external_ids(event)),
      runtime_event: runtime_event_external_ids(event)
    }

    @fallback_metadata_precedence
    |> Enum.map(&Map.fetch!(candidates, &1))
    |> Enum.find(%{}, &fallback_runtime_metadata?/1)
  end

  defp fallback_runtime_metadata?(external_ids) do
    Enum.any?([:execution_id, :job_id, :native_session_id, :thread_id, :session_id], fn key ->
      Map.has_key?(external_ids, key) or Map.has_key?(external_ids, Atom.to_string(key))
    end)
  end

  defp stdout_jsonl_external_ids(event) do
    event
    |> stdout_jsonl_candidates()
    |> Enum.reduce(%{}, fn candidate, acc ->
      Map.merge(acc, stdout_jsonl_candidate_external_ids(candidate))
    end)
  end

  defp stdout_jsonl_candidates(event) do
    [
      Map.get(event, :stdout_jsonl),
      Map.get(event, "stdout_jsonl"),
      Map.get(event, :stdout),
      Map.get(event, "stdout"),
      Map.get(event, :stdout_jsonl_records),
      Map.get(event, "stdout_jsonl_records")
    ]
    |> Enum.flat_map(fn
      nil -> []
      candidates when is_list(candidates) -> candidates
      candidate -> [candidate]
    end)
  end

  defp stdout_jsonl_candidate_external_ids(candidate) when is_binary(candidate) do
    candidate
    |> StdoutJsonlParser.parse()
    |> stdout_jsonl_candidate_external_ids()
  end

  defp stdout_jsonl_candidate_external_ids(candidate) when is_map(candidate) do
    StdoutJsonlParser.extract_codex_external_ids(candidate)
  end

  defp stdout_jsonl_candidate_external_ids(candidates) when is_list(candidates) do
    Enum.reduce(candidates, %{}, fn candidate, acc ->
      Map.merge(acc, stdout_jsonl_candidate_external_ids(candidate))
    end)
  end

  defp stdout_jsonl_candidate_external_ids(_candidate), do: %{}

  defp valid_runtime_external_ids(external_ids) when is_map(external_ids) do
    Enum.reduce(external_ids, %{}, fn {key, value}, acc ->
      if ChildSessionMetadata.runtime_id_key?(key) do
        case ChildSessionMetadata.normalize_runtime_id(value) do
          nil -> acc
          normalized -> Map.put(acc, key, normalized)
        end
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp valid_runtime_external_ids(_external_ids), do: %{}

  defp same_fallback_runtime?(existing, pane) do
    fallback_pane?(existing) and
      not conflicting_same_source_fallback?(existing, pane) and
      Enum.any?(ChildSessionMetadata.runtime_identity_keys(), fn key ->
        ChildSessionMetadata.present_runtime_id(existing.external_ids, key) != nil and
          ChildSessionMetadata.present_runtime_id(existing.external_ids, key) ==
            ChildSessionMetadata.present_runtime_id(pane.external_ids, key)
      end)
  end

  defp conflicting_same_source_fallback?(existing, pane) do
    existing_source = Map.get(existing.external_ids, "fallback_child_id_source")
    pane_source = Map.get(pane.external_ids, "fallback_child_id_source")
    existing_id = Map.get(existing.external_ids, "fallback_child_id")
    pane_id = Map.get(pane.external_ids, "fallback_child_id")

    existing_source != nil and existing_source == pane_source and
      existing_id != nil and pane_id != nil and existing_id != pane_id
  end

  defp reuse_fallback_child_id(pane, existing) do
    child_id = existing.child_id
    source = Map.get(existing.external_ids, "fallback_child_id_source")

    %{
      pane
      | id: existing.id,
        child_id: child_id,
        external_ids:
          pane.external_ids
          |> Map.put("fallback_child_id", child_id)
          |> Map.put("child_id", child_id)
          |> maybe_put_fallback_source(source),
        stream_cursor: Map.put(pane.stream_cursor, :child_id, child_id)
    }
  end

  defp maybe_put_fallback_source(external_ids, nil), do: external_ids

  defp maybe_put_fallback_source(external_ids, source) do
    Map.put(external_ids, "fallback_child_id_source", source)
  end
end
