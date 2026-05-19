defmodule Ourocode.MCP.ChildSessionCreationParser do
  @moduledoc """
  Extracts child agent/session creation IDs from normalized MCP lifecycle events.

  Transports preserve runtime payloads in different lifecycle fields
  (`notification`, `result`, `params`, `external_ids`). This parser keeps child
  ID detection transport-neutral so pane mapping and journal writers can share
  one interpretation of supported runtime payload shapes.
  """

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

  @child_pane_prefix "child-session:"

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
      :ignore -> fallback_when_no_malformed_child_id(event)
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

  defp candidate_payloads(event) do
    [
      {:event, event},
      {:data, field(event, :data)},
      {:data_params, get_nested(event, [:data, "params"])},
      {:data_params, get_nested(event, [:data, :params])},
      {:data_result, get_nested(event, [:data, "result"])},
      {:data_result, get_nested(event, [:data, :result])},
      {:external_ids, field(event, :external_ids)},
      {:params, field(event, :params)},
      {:notification, field(event, :notification)},
      {:notification_params, get_nested(event, [:notification, "params"])},
      {:notification_params, get_nested(event, [:notification, :params])},
      {:notification_result, get_nested(event, [:notification, "result"])},
      {:notification_result, get_nested(event, [:notification, :result])},
      {:result, field(event, :result)},
      {:result_params, get_nested(event, [:result, "params"])},
      {:result_params, get_nested(event, [:result, :params])},
      {:raw_event, field(event, :raw_event)},
      {:raw_event_data, get_nested(event, [:raw_event, "data"])},
      {:raw_event_data, get_nested(event, [:raw_event, :data])},
      {:raw_event_data_params, get_nested(event, [:raw_event, "data", "params"])},
      {:raw_event_data_params, get_nested(event, [:raw_event, :data, :params])},
      {:raw_event_data_result, get_nested(event, [:raw_event, "data", "result"])},
      {:raw_event_data_result, get_nested(event, [:raw_event, :data, :result])},
      {:raw_event_params, get_nested(event, [:raw_event, "params"])},
      {:raw_event_params, get_nested(event, [:raw_event, :params])},
      {:raw_event_result, get_nested(event, [:raw_event, "result"])},
      {:raw_event_result, get_nested(event, [:raw_event, :result])}
    ]
    |> Enum.filter(fn {_path, payload} -> is_map(payload) end)
  end

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
    [
      {:childID, get_in_any(payload, ["childID", :childID])},
      {:childId, get_in_any(payload, ["childId", :childId])},
      {:child_id, get_in_any(payload, ["child_id", :child_id])},
      {:child_session_id,
       get_in_any(payload, [
         "child_session_id",
         :child_session_id,
         "childSessionID",
         :childSessionID,
         "childSessionId",
         :childSessionId
       ])},
      {:agent_session_id,
       get_in_any(payload, [
         "agent_session_id",
         :agent_session_id,
         "agentSessionID",
         :agentSessionID,
         "agentSessionId",
         :agentSessionId
       ])},
      {:opencode_child_id, get_in_any(payload, ["opencode_childID", :opencode_childID])},
      {:pane_key, get_in_any(payload, ["pane_key", :pane_key, "paneKey", :paneKey])}
    ]
    |> Enum.find_value(fn {source, value} ->
      case normalize_explicit_child_id(source, value) do
        nil -> nil
        child_id -> {child_id, source}
      end
    end)
  end

  defp explicit_child_id(_payload), do: nil

  defp fallback_when_no_malformed_child_id(event) do
    if malformed_child_id_present?(event) do
      :ignore
    else
      fallback_extraction(event)
    end
  end

  defp malformed_child_id_present?(event) do
    event
    |> candidate_payloads()
    |> Enum.any?(fn {_path, payload} -> malformed_child_id_payload?(payload) end)
  end

  defp malformed_child_id_payload?(payload) when is_map(payload) do
    [
      ["childID", :childID],
      ["childId", :childId],
      ["child_id", :child_id],
      [
        "child_session_id",
        :child_session_id,
        "childSessionID",
        :childSessionID,
        "childSessionId",
        :childSessionId
      ],
      [
        "agent_session_id",
        :agent_session_id,
        "agentSessionID",
        :agentSessionID,
        "agentSessionId",
        :agentSessionId
      ],
      ["opencode_childID", :opencode_childID],
      ["pane_key", :pane_key, "paneKey", :paneKey]
    ]
    |> Enum.any?(fn keys ->
      Enum.any?(keys, fn key ->
        Map.has_key?(payload, key) and
          normalize_candidate_child_id(key, Map.get(payload, key)) == nil
      end)
    end)
  end

  defp malformed_child_id_payload?(_payload), do: false

  defp fallback_extraction(event) do
    with true <- fallback_eligible?(event),
         {:ok, _parent_call_id} <- required_runtime_id(event, :parent_call_id),
         {source, value} <- fallback_runtime_id(event) do
      child_id = "fallback:" <> Atom.to_string(source) <> ":" <> value

      {:ok, extraction(child_id, {:fallback, source}, :fallback_runtime_id)}
    else
      nil ->
        {:unresolved,
         %{
           status: :unresolved,
           reason: :missing_fallback_runtime_metadata,
           parent_call_id: runtime_id_value(event, :parent_call_id),
           checked_sources: fallback_runtime_id_sources()
         }}

      _ -> :ignore
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
    |> get_in_any([
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

  defp fallback_runtime_id(event) do
    runtime_ids = fallback_runtime_ids(event)

    fallback_runtime_id_sources()
    |> Enum.map(fn
      :input_session_id ->
        {:input_session_id,
         nested_runtime_id_value(runtime_ids, :input, :sessionID) ||
           runtime_id_value(runtime_ids, :input_sessionID)}

      :input_call_id ->
        {:input_call_id,
         nested_runtime_id_value(runtime_ids, :input, :callID) ||
           runtime_id_value(runtime_ids, :input_callID)}

      :request_id ->
        {:request_id, runtime_id_value(event, :request_id)}

      source ->
        {source, runtime_id_value(runtime_ids, source)}
    end)
    |> Enum.find(fn {_source, value} -> present?(value) end)
  end

  defp fallback_runtime_id_sources do
    [
      :execution_id,
      :job_id,
      :lineage_id,
      :native_session_id,
      :thread_id,
      :session_id,
      :input_session_id,
      :input_call_id,
      :call_id,
      :request_id
    ]
  end

  defp fallback_runtime_ids(event) do
    case field(event, :fallback_runtime_metadata) do
      metadata when is_map(metadata) and map_size(metadata) > 0 -> metadata
      _ -> runtime_ids(event)
    end
  end

  defp runtime_ids(event) do
    event_external_ids =
      case field(event, :external_ids) do
        external_ids when is_map(external_ids) -> valid_runtime_ids(external_ids)
        _ -> %{}
      end

    event
    |> Ourocode.MCP.RuntimeEventParser.extract_external_ids()
    |> Map.merge(event_external_ids)
  end

  defp valid_runtime_ids(runtime_ids) do
    Enum.reduce(runtime_ids, %{}, fn {key, value}, acc ->
      cond do
        is_map(value) ->
          Map.put(acc, key, value)

        true ->
          case normalize_runtime_id(value) do
            nil -> acc
            normalized -> Map.put(acc, key, normalized)
          end
      end
    end)
  end

  defp runtime_id_value(map, key) when is_map(map) do
    map
    |> get_in_any([key, Atom.to_string(key)])
    |> normalize_runtime_id()
  end

  defp runtime_id_value(_map, _key), do: nil

  defp nested_runtime_id_value(map, parent_key, child_key) when is_map(map) do
    map
    |> get_in_any([parent_key, Atom.to_string(parent_key)])
    |> case do
      nested when is_map(nested) -> runtime_id_value(nested, child_key)
      _ -> nil
    end
  end

  defp nested_runtime_id_value(_map, _parent_key, _child_key), do: nil

  defp required_runtime_id(event, key) do
    case runtime_id_value(event, key) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp event_type(event) do
    value = get_in_any(event, [:type, "type"])

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

  defp field(map, key) do
    get_in_any(map, [key, Atom.to_string(key)])
  end

  defp get_nested(map, keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      cond do
        is_map(acc) and Map.has_key?(acc, key) -> {:cont, Map.get(acc, key)}
        is_map(acc) and is_atom(key) and Map.has_key?(acc, Atom.to_string(key)) ->
          {:cont, Map.get(acc, Atom.to_string(key))}

        is_map(acc) and is_binary(key) ->
          atom_key = safe_existing_atom(key)

          if atom_key && Map.has_key?(acc, atom_key) do
            {:cont, Map.get(acc, atom_key)}
          else
            {:halt, nil}
          end

        true ->
          {:halt, nil}
      end
    end)
  end

  defp get_in_any(map, keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp normalize_runtime_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_runtime_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_runtime_id(_value), do: nil

  defp normalize_child_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_child_id(_value), do: nil

  defp normalize_explicit_child_id(:pane_key, value), do: normalize_pane_key(value)
  defp normalize_explicit_child_id(_source, value), do: normalize_child_id(value)

  defp normalize_candidate_child_id(key, value)
       when key in ["pane_key", :pane_key, "paneKey", :paneKey] do
    normalize_pane_key(value)
  end

  defp normalize_candidate_child_id(_key, value), do: normalize_child_id(value)

  defp normalize_pane_key(value) when is_binary(value) do
    value
    |> normalize_child_id()
    |> case do
      "child-session:" <> child_id -> normalize_child_id(child_id)
      _other -> nil
    end
  end

  defp normalize_pane_key(_value), do: nil

  defp extraction(child_id, source, payload_path) do
    %{
      child_id: child_id,
      pane_key: pane_key(child_id),
      source: source,
      payload_path: payload_path
    }
  end

  defp pane_key(child_id), do: @child_pane_prefix <> child_id

  defp present?(value), do: value not in [nil, ""]

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
