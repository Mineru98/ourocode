defmodule Ourocode.Journal do
  @moduledoc """
  Local JSONL event journal for ourocode runtime recovery.

  The journal stores normalized lifecycle events as append-only records. Runtime
  IDs and statuses remain trusted from the external source; ourocode persists
  local mappings, cursors, pane inputs, and cleanup-relevant state so the UI can
  recover an ordered stream after a restart.
  """

  use GenServer

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.Journal.CleanupEventDecoder
  alias Ourocode.Journal.CleanupRecoveryIndex
  alias Ourocode.Journal.RelationshipEventDecoder
  alias Ourocode.Journal.RelationshipRecoveryIndex
  alias Ourocode.Journal.SourceTransportNormalizer

  @known_top_level_keys %{
    "call_id" => :call_id,
    "acknowledged_stream_cursor" => :acknowledged_stream_cursor,
    "args" => :args,
    "command" => :command,
    "completion_metadata" => :completion_metadata,
    "config_source_exists?" => :config_source_exists?,
    "config_source_path" => :config_source_path,
    "config_source_relative_path" => :config_source_relative_path,
    "config_source_signature" => :config_source_signature,
    "cleanup_action" => :cleanup_action,
    "cleanup_reason" => :cleanup_reason,
    "cleanup_started_monotonic_ms" => :cleanup_started_monotonic_ms,
    "child_event_id" => :child_event_id,
    "change" => :change,
    "cleanup_state" => :cleanup_state,
    "error" => :error,
    "error_details" => :error_details,
    "error_type" => :error_type,
    "event_seq" => :event_seq,
    "external_ids" => :external_ids,
    "focused" => :focused,
    "headers" => :headers,
    "hook_id" => :hook_id,
    "input_kind" => :input_kind,
    "layout" => :layout,
    "last_acknowledged_stream_cursor" => :last_acknowledged_stream_cursor,
    "method" => :method,
    "notification" => :notification,
    "occurred_at_ms" => :occurred_at_ms,
    "open" => :open,
    "operation_id" => :operation_id,
    "opened_event_seq" => :opened_event_seq,
    "ordering_metadata" => :ordering_metadata,
    "child_id" => :child_id,
    "created_at_ms" => :created_at_ms,
    "event_type" => :event_type,
    "focused_pane" => :focused_pane,
    "idempotency_key" => :idempotency_key,
    "key" => :key,
    "pane_id" => :pane_id,
    "pane_state" => :pane_state,
    "pane_layouts" => :pane_layouts,
    "params" => :params,
    "parent_call_id" => :parent_call_id,
    "payload" => :payload,
    "plugin_id" => :plugin_id,
    "plugin_settings" => :plugin_settings,
    "plugin_pane_settings" => :plugin_pane_settings,
    "progress_state" => :progress_state,
    "previous_focused_pane" => :previous_focused_pane,
    "raw_event" => :raw_event,
    "raw_input" => :raw_input,
    "reason" => :reason,
    "recoverable?" => :recoverable?,
    "relevance" => :relevance,
    "relevant?" => :relevant?,
    "request_id" => :request_id,
    "requested_pane_id" => :requested_pane_id,
    "rendered_event_seq" => :rendered_event_seq,
    "rendered_index" => :rendered_index,
    "rendered_sequence" => :rendered_sequence,
    "rendered_sequence_id" => :rendered_sequence_id,
    "routing_decision" => :routing_decision,
    "released_resources" => :released_resources,
    "replay_action" => :replay_action,
    "result" => :result,
    "runtime_source" => :runtime_source,
    "runtime_seq" => :runtime_seq,
    "reload_boundary" => :reload_boundary,
    "settings_source_exists?" => :settings_source_exists?,
    "settings_source_path" => :settings_source_path,
    "settings_source_relative_path" => :settings_source_relative_path,
    "settings_source_signature" => :settings_source_signature,
    "question_id" => :question_id,
    "question_kind" => :question_kind,
    "selected_at_ms" => :selected_at_ms,
    "selected_description" => :selected_description,
    "selected_index" => :selected_index,
    "selected_label" => :selected_label,
    "selected_option" => :selected_option,
    "selected_registry_item" => :selected_registry_item,
    "selected_slash" => :selected_slash,
    "selection_index" => :selection_index,
    "session_id" => :session_id,
    "session_pid" => :session_pid,
    "session_settings" => :session_settings,
    "source" => :source,
    "status" => :status,
    "stale_cleanup_timeout_ms" => :stale_cleanup_timeout_ms,
    "steering_target" => :steering_target,
    "steering_target_kind" => :steering_target_kind,
    "steering_target_pane_id" => :steering_target_pane_id,
    "steering_target_session_id" => :steering_target_session_id,
    "steering_message" => :steering_message,
    "steering_text" => :steering_text,
    "stream_cursor" => :stream_cursor,
    "stream_kind" => :stream_kind,
    "stream_subscription_cleanup_timeout_ms" => :stream_subscription_cleanup_timeout_ms,
    "submitted_at_ms" => :submitted_at_ms,
    "task_input" => :task_input,
    "task_request_id" => :task_request_id,
    "transport" => :transport,
    "type" => :type,
    "updated_at_ms" => :updated_at_ms,
    "ui_restart_required?" => :ui_restart_required?,
    "watcher_id" => :watcher_id
  }

  @known_atoms %{
    "parent_call_event" => :parent_call_event,
    "parent_call_failed" => :parent_call_failed,
    "parent_call_result" => :parent_call_result,
    "parent_call_started" => :parent_call_started,
    "parent_call_unmatched_result" => :parent_call_unmatched_result,
    "parent_call_write_failed" => :parent_call_write_failed,
    "child_stream_event" => :child_stream_event,
    "dashboard_layout_applied" => :dashboard_layout_applied,
    "dashboard_layout_updated" => :dashboard_layout_updated,
    "layout_applied" => :layout_applied,
    "layout_updated" => :layout_updated,
    "child_pane_registered" => :child_pane_registered,
    "child_pane_opened" => :child_pane_opened,
    "child_pane_focused" => :child_pane_focused,
    "child_pane_updated" => :child_pane_updated,
    "child_pane_completed" => :child_pane_completed,
    "child_pane_cancelled" => :child_pane_cancelled,
    "transport_cleanup" => :transport_cleanup,
    "stream_cleanup" => :stream_cleanup,
    "transport_exited" => :transport_exited,
    "transport_started" => :transport_started,
    "transport_connected" => :transport_connected,
    "transport_closed" => :transport_closed,
    "transport_decode_failed" => :transport_decode_failed,
    "transport_failed" => :transport_failed,
    "transport_metadata" => :transport_metadata,
    "prompt_input_submitted" => :prompt_input_submitted,
    "pane_directed_steering_message" => :pane_directed_steering_message,
    "slash_command_submitted" => :slash_command_submitted,
    "slash_command_failed" => :slash_command_failed,
    "command_registry_updated" => :command_registry_updated,
    "command_palette_opened" => :command_palette_opened,
    "command_palette_selected" => :command_palette_selected,
    "slash_palette_trigger" => :slash_palette_trigger,
    "slash_palette_selection" => :slash_palette_selection,
    "command_palette_open" => :command_palette_open,
    "command_palette_select" => :command_palette_select,
    "command_palette_selection_failed" => :command_palette_selection_failed,
    "terminal_recoverable_error" => :terminal_recoverable_error,
    "hook_started" => :hook_started,
    "hook_progress" => :hook_progress,
    "hook_response" => :hook_response,
    "hook_completed" => :hook_completed,
    "terminal_prompt" => :terminal_prompt,
    "terminal_runtime_event_poll" => :terminal_runtime_event_poll,
    "runtime_event_poll_failed" => :runtime_event_poll_failed,
    "runtime_event_handler_failed" => :runtime_event_handler_failed,
    "recoverable_error" => :recoverable_error,
    "recoverable_stream_gap" => :recoverable_stream_gap,
    "runtime_startup_succeeded" => :runtime_startup_succeeded,
    "natural_language" => :natural_language,
    "slash_command" => :slash_command,
    "dashboard" => :dashboard,
    "cli" => :cli,
    "wonder_decision" => :wonder_decision,
    "decision" => :decision,
    "permission" => :permission,
    "clarification" => :clarification,
    "socratic" => :socratic,
    "working" => :working,
    "completed" => :completed,
    "cancelled" => :cancelled,
    "canceled" => :canceled,
    "idle_timeout" => :idle_timeout,
    "operation_timeout" => :operation_timeout,
    "child" => :child,
    "session" => :session,
    "transport" => :transport,
    "already_completed" => :already_completed,
    "noop" => :noop,
    "release_runtime_resources" => :release_runtime_resources,
    "stdio" => :stdio,
    "streamable_http" => :streamable_http,
    "sse" => :sse,
    "runtime" => :runtime,
    "pane_model" => :pane_model,
    "plugin_registry" => :plugin_registry,
    "command_registry" => :command_registry,
    "dynamic_skill_discovery" => :dynamic_skill_discovery,
    "plugin_runtime" => :plugin_runtime,
    "terminal_keyboard" => :terminal_keyboard,
    "terminal_command" => :terminal_command,
    "keyboard" => :keyboard,
    "keyboard_focus_failed" => :keyboard_focus_failed,
    "focus_state_updated" => :focus_state_updated,
    "focused_pane" => :focused_pane,
    "previous_focused_pane" => :previous_focused_pane,
    "hook_lifecycle" => :hook_lifecycle,
    "event_pipeline" => :event_pipeline,
    "rendered_sequence_entry" => :rendered_sequence_entry,
    "plugin_loaded" => :plugin_loaded,
    "plugin_config_reloaded" => :plugin_config_reloaded,
    "plugin_config_reload_requested" => :plugin_config_reload_requested,
    "plugin_settings_applied" => :plugin_settings_applied,
    "plugin_settings_reload_requested" => :plugin_settings_reload_requested,
    "plugin_config_source_changed" => :plugin_config_source_changed,
    "plugin_scoped_settings_changed" => :plugin_scoped_settings_changed,
    "relevant_config_change" => :relevant_config_change,
    "relevant_plugin_settings_change" => :relevant_plugin_settings_change,
    "plugin_config_watcher" => :plugin_config_watcher,
    "loaded" => :loaded,
    "invalid" => :invalid,
    "missing" => :missing,
    "created" => :created,
    "modified" => :modified,
    "deleted" => :deleted,
    "elixir_runtime" => :elixir_runtime,
    "temporary_backpressure" => :temporary_backpressure,
    "third_party" => :third_party
  }

  @normalized_event_diagnostic_keys MapSet.new(["raw_event"])
  @raw_event_encoded_map_marker "__ourocode_raw_event_encoded_map__"
  @raw_event_encoded_map_entries "entries"
  @raw_event_encoded_value_marker "__ourocode_raw_event_encoded_value__"

  @type entry :: map()
  @server __MODULE__.Writer

  @doc """
  Appends one normalized event to a JSONL journal file.
  """
  @spec append(Path.t(), map() | LifecycleEvent.t()) :: :ok | {:error, term()}
  def append(path, event) when is_binary(path) do
    with {:ok, pid} <- ensure_writer_started() do
      GenServer.call(pid, {:append, path, event}, :infinity)
    end
  end

  @doc """
  Appends one normalized event and returns the durable journal record.

  This is for ingestion boundaries that need to keep using the accepted event
  after persistence. The returned map is restored through the normal replay
  decoder, so callers observe the same `event_seq` and normalized field shape
  that journal replay will later reconstruct.
  """
  @spec append_returning_event(Path.t(), map() | LifecycleEvent.t()) ::
          {:ok, entry()} | {:error, term()}
  def append_returning_event(path, event) when is_binary(path) do
    with {:ok, pid} <- ensure_writer_started() do
      GenServer.call(pid, {:append_returning_event, path, event}, :infinity)
    end
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:append, path, event}, _from, state) do
    result = append_unlocked(path, event)
    {:reply, result, state}
  end

  def handle_call({:append_returning_event, path, event}, _from, state) do
    result = append_unlocked_returning_event(path, event)
    {:reply, result, state}
  end

  @doc """
  Appends one normalized event, raising if persistence fails.
  """
  @spec append!(Path.t(), map() | LifecycleEvent.t()) :: :ok
  def append!(path, event) when is_binary(path) do
    case append(path, event) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "append journal", path: path
    end
  end

  @doc """
  Returns the stable UI identity for one journaled child stream event.

  The identity is derived from metadata persisted with the normalized journal
  record, not from read order or render position. Reading the same journal
  record repeatedly therefore produces the same child event identity.
  """
  @spec child_event_identity(entry()) :: {:ok, String.t()} | {:error, term()}
  def child_event_identity(%{} = entry) do
    with child_id when is_binary(child_id) and child_id != "" <- entry_child_id(entry),
         event_seq when is_integer(event_seq) <- map_value(entry, :event_seq) do
      {:ok,
       [
         "child-event",
         identity_component(:parent, map_value(entry, :parent_call_id)),
         identity_component(:child, child_id),
         identity_component(:runtime, map_value(entry, :runtime_source)),
         identity_component(:transport, map_value(entry, :transport)),
         identity_component(:event_seq, event_seq),
         identity_component(:runtime_seq, child_runtime_seq(entry))
       ]
       |> Enum.join(":")}
    else
      nil -> {:error, :missing_child_event_identity}
      _value -> {:error, :missing_child_event_identity}
    end
  end

  def child_event_identity(_entry), do: {:error, :missing_child_event_identity}

  @doc """
  Persists every rendered stream sequence from a rendered child pane.

  The journal keeps its own top-level `event_seq` for no-loss ordering. The
  stream event sequence shown in the UI is persisted as `rendered_event_seq` so
  render-sequence records cannot create false journal gaps.
  """
  @spec append_rendered_sequences(Path.t(), map()) :: :ok | {:error, term()}
  def append_rendered_sequences(path, rendered_pane)
      when is_binary(path) and is_map(rendered_pane) do
    rendered_pane
    |> rendered_sequence_records()
    |> append_records(path)
  end

  @doc """
  Verifies that every rendered sequence identifier is present in the journal.

  This check proves the render model did not advance beyond durable journal
  state. It compares stable `rendered_sequence_id` values from journaled
  `rendered_sequence_entry` records against the identifiers currently exposed by
  rendered panes.
  """
  @spec verify_rendered_sequences_journaled([entry()], term()) :: {:ok, map()} | {:error, map()}
  def verify_rendered_sequences_journaled(journal_entries, rendered_output)
      when is_list(journal_entries) do
    journaled_ids =
      journal_entries
      |> Enum.flat_map(&journaled_rendered_sequence_ids/1)
      |> MapSet.new()

    rendered_sequences = rendered_sequence_summaries(rendered_output)

    missing =
      rendered_sequences
      |> Enum.reject(&MapSet.member?(journaled_ids, &1.rendered_sequence_id))

    report = %{
      type: :rendered_sequence_journal_reconciliation,
      status: if(missing == [], do: :ok, else: :failed),
      journaled_rendered_sequence_count: MapSet.size(journaled_ids),
      rendered_sequence_count: length(rendered_sequences),
      journaled_rendered_sequence_ids: journaled_ids |> MapSet.to_list() |> Enum.sort(),
      rendered_sequence_ids:
        rendered_sequences
        |> Enum.map(& &1.rendered_sequence_id)
        |> Enum.uniq()
        |> Enum.sort(),
      missing_journaled_rendered_sequences: missing
    }

    if missing == [] do
      {:ok, report}
    else
      {:error,
       report
       |> Map.put(:reason, :rendered_sequences_missing_from_journal)
       |> Map.put(:missing_count, length(missing))}
    end
  end

  @doc """
  Reconciles completed child streams from the normalized journal with render output.

  Only child streams that have a `child_pane_completed` journal marker are
  checked. For those streams, every journaled `parent_call_event` sequence for
  that child must be present in the rendered sequence set. Missing rendered
  events return a structured failure report instead of being silently ignored.
  """
  @spec reconcile_completed_child_streams([entry()], term()) :: {:ok, map()} | {:error, map()}
  def reconcile_completed_child_streams(journal_entries, rendered_output)
      when is_list(journal_entries) do
    completed_child_ids = completed_child_ids(journal_entries)
    rendered_event_keys = rendered_event_keys(rendered_output)

    missing =
      journal_entries
      |> Enum.filter(&journaled_child_stream_event?(&1, completed_child_ids))
      |> Enum.reject(&MapSet.member?(rendered_event_keys, journaled_event_key(&1)))
      |> Enum.map(&missing_rendered_event/1)

    report = %{
      type: :journal_to_render_reconciliation,
      status: if(missing == [], do: :ok, else: :failed),
      completed_child_ids: MapSet.to_list(completed_child_ids) |> Enum.sort(),
      journaled_event_count:
        Enum.count(journal_entries, &journaled_child_stream_event?(&1, completed_child_ids)),
      rendered_event_count: MapSet.size(rendered_event_keys),
      missing_rendered_events: missing
    }

    if missing == [] do
      {:ok, report}
    else
      {:error,
       report
       |> Map.put(:reason, :journaled_child_stream_events_missing_from_render)
       |> Map.put(:missing_count, length(missing))}
    end
  end

  @doc """
  Compares journaled normalized events with the normalized source event stream.

  The comparison is duplicate-safe and order-aware. Events with `event_seq` use
  that sequence as their stable identity; events without one fall back to a
  canonical event fingerprint plus occurrence index. The report distinguishes
  source events missing from the journal, journal records with no source event,
  and records with the same normalized identity but different normalized
  content.
  """
  @spec compare_normalized_events([entry()], [map() | LifecycleEvent.t()]) ::
          {:ok, map()} | {:error, map()}
  def compare_normalized_events(journaled_events, source_events)
      when is_list(journaled_events) and is_list(source_events) do
    journaled_index = normalized_event_index(journaled_events)
    source_index = normalized_event_index(source_events)

    journaled_keys = journaled_index |> Map.keys() |> MapSet.new()
    source_keys = source_index |> Map.keys() |> MapSet.new()

    missing =
      source_keys
      |> MapSet.difference(journaled_keys)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(&comparison_event_summary(source_index, &1))

    extra =
      journaled_keys
      |> MapSet.difference(source_keys)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(&comparison_event_summary(journaled_index, &1))

    mismatched =
      source_keys
      |> MapSet.intersection(journaled_keys)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.reduce([], fn key, acc ->
        source = Map.fetch!(source_index, key)
        journaled = Map.fetch!(journaled_index, key)

        if source.canonical == journaled.canonical do
          acc
        else
          [
            %{
              identity: normalized_event_identity_report(key),
              source_index: source.index,
              journaled_index: journaled.index,
              differing_fields:
                differing_normalized_fields(source.canonical, journaled.canonical),
              source_event: source.canonical,
              journaled_event: journaled.canonical
            }
            | acc
          ]
        end
      end)
      |> Enum.reverse()

    report = %{
      type: :normalized_event_no_loss_comparison,
      status: if(missing == [] and extra == [] and mismatched == [], do: :ok, else: :failed),
      source_event_count: length(source_events),
      journaled_event_count: length(journaled_events),
      missing_count: length(missing),
      extra_count: length(extra),
      mismatched_count: length(mismatched),
      missing_normalized_events: missing,
      extra_normalized_events: extra,
      mismatched_normalized_events: mismatched
    }

    if report.status == :ok do
      {:ok, report}
    else
      {:error, Map.put(report, :reason, :normalized_event_no_loss_comparison_failed)}
    end
  end

  @doc """
  Normalizes raw source transport events, then runs the no-loss comparison.

  This is the validation pipeline entry point for transport-level evidence:
  stdio JSONL lines/messages, parsed or raw SSE frames, and streamable HTTP
  responses are first converted into canonical lifecycle events. Only then are
  they compared against the journal with `compare_normalized_events/2`.
  """
  @spec compare_source_transport_events(
          [entry()],
          [map() | LifecycleEvent.t()],
          keyword() | map()
        ) ::
          {:ok, map()} | {:error, map()}
  def compare_source_transport_events(journaled_events, source_transport_events, options \\ [])
      when is_list(journaled_events) and is_list(source_transport_events) do
    with {:ok, normalized_source_events, normalization_report} <-
           SourceTransportNormalizer.normalize(source_transport_events, options) do
      case compare_normalized_events(journaled_events, normalized_source_events) do
        {:ok, report} ->
          {:ok, Map.put(report, :source_normalization, normalization_report)}

        {:error, report} ->
          {:error, Map.put(report, :source_normalization, normalization_report)}
      end
    end
  end

  @doc """
  Reads journal entries in file order.
  """
  @spec read(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path) do
      entries =
        contents
        |> String.split(["\r\n", "\n", "\r"], trim: true)
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
          case Ourocode.Json.decode(line) do
            {:ok, record} when is_map(record) -> {:cont, {:ok, [restore(record) | acc]}}
            {:ok, _other} -> {:halt, {:error, {:invalid_journal_record, line}}}
            {:error, reason} -> {:halt, {:error, {:invalid_journal_json, reason}}}
          end
        end)

      case entries do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Reads journal entries in file order and verifies a contiguous `event_seq`.
  """
  @spec read_ordered(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def read_ordered(path) when is_binary(path) do
    with {:ok, entries} <- read(path) do
      case verify_no_event_seq_gaps(entries) do
        :ok -> {:ok, entries}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Reconstructs normalized events from a journal replay.

  This is intentionally the same ordered restore path used by runtime recovery:
  every persisted normalized field, including transport-specific `raw_event`
  debug metadata, is decoded before the event stream is returned.
  """
  @spec replay_normalized_events(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def replay_normalized_events(path) when is_binary(path), do: read_ordered(path)

  @doc """
  Loads typed parent-call to child-session relationship recovery records.

  Non-relationship journal events are ignored. Relationship events preserve
  trusted external runtime identifiers while exposing the local pane ID,
  cursor, and child/session mapping needed for UI recovery.
  """
  @spec load_relationship_recovery_records(Path.t()) ::
          {:ok, [Ourocode.Journal.RelationshipRecoveryRecord.t()]} | {:error, term()}
  def load_relationship_recovery_records(path) when is_binary(path) do
    with {:ok, entries} <- read_ordered(path) do
      RelationshipEventDecoder.decode_all(entries)
    end
  end

  @doc """
  Builds a parent-call to child-session recovery index from decoded records.
  """
  @spec build_relationship_recovery_index([Ourocode.Journal.RelationshipRecoveryRecord.t()]) ::
          {:ok, RelationshipRecoveryIndex.t()} | {:error, term()}
  def build_relationship_recovery_index(records) when is_list(records) do
    RelationshipRecoveryIndex.build(records)
  end

  @doc """
  Loads decoded relationship records and reconstructs recovery lookup indexes.
  """
  @spec load_relationship_recovery_index(Path.t()) ::
          {:ok, RelationshipRecoveryIndex.t()} | {:error, term()}
  def load_relationship_recovery_index(path) when is_binary(path) do
    with {:ok, records} <- load_relationship_recovery_records(path) do
      build_relationship_recovery_index(records)
    end
  end

  @doc """
  Loads typed cleanup recovery records from journal cleanup and completion events.

  Cleanup recovery trusts external runtime status but keeps ourocode-owned local
  cleanup state: child/session/transport keys, cursors, pane state, released
  resource counts, and replay action markers used after restart.
  """
  @spec load_cleanup_recovery_records(Path.t()) ::
          {:ok, [Ourocode.Journal.CleanupRecoveryRecord.t()]} | {:error, term()}
  def load_cleanup_recovery_records(path) when is_binary(path) do
    with {:ok, entries} <- read_ordered(path) do
      CleanupEventDecoder.decode_all(entries)
    end
  end

  @doc """
  Builds cleanup recovery indexes from decoded cleanup records.
  """
  @spec build_cleanup_recovery_index([Ourocode.Journal.CleanupRecoveryRecord.t()]) ::
          {:ok, CleanupRecoveryIndex.t()} | {:error, term()}
  def build_cleanup_recovery_index(records) when is_list(records) do
    CleanupRecoveryIndex.build(records)
  end

  @doc """
  Loads cleanup records and reconstructs cleanup replay state.
  """
  @spec load_cleanup_recovery_index(Path.t()) ::
          {:ok, CleanupRecoveryIndex.t()} | {:error, term()}
  def load_cleanup_recovery_index(path) when is_binary(path) do
    with {:ok, records} <- load_cleanup_recovery_records(path) do
      build_cleanup_recovery_index(records)
    end
  end

  @doc """
  Verifies that journal `event_seq` values are contiguous in file order.

  A full runtime journal normally starts at 1, while focused journal fragments
  can start at a later high-watermark. Both forms are valid as long as no event
  is skipped within the fragment being read.
  """
  @spec verify_no_event_seq_gaps([entry()]) :: :ok | {:error, term()}
  def verify_no_event_seq_gaps(entries) when is_list(entries) do
    seqs = Enum.map(entries, &Map.get(&1, :event_seq))

    expected =
      case seqs do
        [] -> []
        [first | _] when is_integer(first) -> Enum.to_list(first..(first + length(seqs) - 1)//1)
        _ -> []
      end

    if seqs == expected do
      :ok
    else
      {:error, {:event_seq_gap, expected, seqs}}
    end
  end

  defp ensure_parent_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp ensure_writer_started do
    case GenServer.start(__MODULE__, %{}, name: @server) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:already_registered, pid}} when is_pid(pid) -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_unlocked(path, event) do
    case append_unlocked_returning_event(path, event) do
      {:ok, _record} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_unlocked_returning_event(path, event) do
    with :ok <- ensure_parent_dir(path),
         {:ok, record} <- record_for_append(path, event),
         :ok <- File.write(path, [Ourocode.Json.encode!(record), "\n"], [:append, :binary]) do
      {:ok, restore(record)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_records(records, path) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case append(path, record) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp completed_child_ids(entries) do
    entries
    |> Enum.reduce(MapSet.new(), fn entry, acc ->
      if child_completion_event?(entry) do
        case entry_child_id(entry) do
          nil -> acc
          child_id -> MapSet.put(acc, child_id)
        end
      else
        acc
      end
    end)
  end

  defp child_completion_event?(entry) when is_map(entry) do
    event_type(entry) == :child_pane_completed or
      (event_type(entry) == :child_pane_updated and entry_status(entry) == :completed)
  end

  defp child_completion_event?(_entry), do: false

  defp journaled_child_stream_event?(entry, completed_child_ids) when is_map(entry) do
    event_type(entry) == :parent_call_event and
      child_stream_payload?(entry) and
      MapSet.member?(completed_child_ids, entry_child_id(entry))
  end

  defp journaled_child_stream_event?(_entry, _completed_child_ids), do: false

  defp child_stream_payload?(entry) do
    payload = map_value(entry, :payload)

    is_map(payload) and payload != %{}
  end

  defp journaled_event_key(entry), do: {entry_child_id(entry), map_value(entry, :event_seq)}

  defp rendered_event_keys(rendered_output) do
    rendered_output
    |> rendered_sequence_sources()
    |> Enum.reduce(MapSet.new(), fn source, acc ->
      source
      |> rendered_sequence_keys()
      |> Enum.reduce(acc, &MapSet.put(&2, &1))
    end)
  end

  defp journaled_rendered_sequence_ids(%{} = entry) do
    if rendered_sequence_entry?(entry) do
      entry
      |> rendered_sequence_id()
      |> List.wrap()
    else
      []
    end
  end

  defp journaled_rendered_sequence_ids(_entry), do: []

  defp rendered_sequence_summaries(rendered_output) do
    rendered_output
    |> rendered_sequence_sources()
    |> Enum.flat_map(&source_rendered_sequence_summaries/1)
    |> Enum.reject(&is_nil(&1.rendered_sequence_id))
  end

  defp source_rendered_sequence_summaries(%{} = rendered_pane) do
    if rendered_sequence_entry?(rendered_pane) do
      rendered_pane
      |> rendered_sequence_summary()
      |> List.wrap()
    else
      child_id = entry_child_id(rendered_pane)
      pane_id = pane_id(rendered_pane)

      rendered_pane
      |> rendered_sequences()
      |> Enum.map(fn sequence ->
        rendered_sequence_summary(sequence, child_id, pane_id)
      end)
    end
  end

  defp source_rendered_sequence_summaries(_source), do: []

  defp rendered_sequence_summary(entry) when is_map(entry) do
    %{
      rendered_sequence_id: rendered_sequence_id(entry),
      child_id: entry_child_id(entry),
      pane_id: map_value(entry, :pane_id),
      rendered_event_seq: map_value(entry, :rendered_event_seq) || map_value(entry, :event_seq),
      runtime_seq: map_value(entry, :runtime_seq),
      rendered_index: map_value(entry, :rendered_index)
    }
  end

  defp rendered_sequence_summary(sequence, fallback_child_id, fallback_pane_id)
       when is_map(sequence) do
    %{
      rendered_sequence_id: rendered_sequence_id(sequence),
      child_id: entry_child_id(sequence) || fallback_child_id,
      pane_id: map_value(sequence, :pane_id) || fallback_pane_id,
      rendered_event_seq:
        map_value(sequence, :event_seq) || map_value(sequence, :rendered_event_seq),
      runtime_seq: map_value(sequence, :runtime_seq),
      rendered_index: map_value(sequence, :rendered_index)
    }
  end

  defp rendered_sequence_id(entry) when is_map(entry) do
    map_value(entry, :rendered_sequence_id) || map_value(entry, :id)
  end

  defp rendered_sequence_entry?(entry) do
    event_type(entry) in [:rendered_sequence_entry, "rendered_sequence_entry"]
  end

  defp rendered_sequence_sources(rendered_output) when is_list(rendered_output) do
    Enum.flat_map(rendered_output, &rendered_sequence_sources/1)
  end

  defp rendered_sequence_sources(%{type: :rendered_sequence_entry} = entry), do: [entry]
  defp rendered_sequence_sources(%{"type" => "rendered_sequence_entry"} = entry), do: [entry]
  defp rendered_sequence_sources(%{"type" => :rendered_sequence_entry} = entry), do: [entry]

  defp rendered_sequence_sources(rendered_output) when is_map(rendered_output) do
    pane_sequences =
      Map.get(rendered_output, :rendered_sequences) ||
        Map.get(rendered_output, "rendered_sequences")

    child_collections =
      [:working, :completed, "working", "completed"]
      |> Enum.flat_map(fn key ->
        case Map.get(rendered_output, key) do
          panes when is_list(panes) -> panes
          _panes -> []
        end
      end)

    cond do
      is_list(pane_sequences) ->
        [rendered_output]

      child_collections != [] ->
        Enum.flat_map(child_collections, &rendered_sequence_sources/1)

      true ->
        []
    end
  end

  defp rendered_sequence_sources(_rendered_output), do: []

  defp rendered_sequence_keys(%{type: :rendered_sequence_entry} = entry) do
    [{entry_child_id(entry), map_value(entry, :rendered_event_seq)}]
  end

  defp rendered_sequence_keys(%{} = rendered_pane) do
    child_id = entry_child_id(rendered_pane)

    rendered_pane
    |> rendered_sequences()
    |> Enum.map(fn sequence ->
      {entry_child_id(sequence) || child_id,
       map_value(sequence, :event_seq) || map_value(sequence, :rendered_event_seq)}
    end)
  end

  defp rendered_sequence_keys(_source), do: []

  defp rendered_sequences(rendered_pane) do
    case Map.get(rendered_pane, :rendered_sequences) ||
           Map.get(rendered_pane, "rendered_sequences") do
      sequences when is_list(sequences) -> sequences
      _sequences -> []
    end
  end

  defp missing_rendered_event(entry) do
    %{
      child_event_id: child_event_identity_value(entry),
      child_id: entry_child_id(entry),
      event_seq: map_value(entry, :event_seq),
      parent_call_id: map_value(entry, :parent_call_id),
      transport: map_value(entry, :transport),
      occurred_at_ms: map_value(entry, :occurred_at_ms)
    }
  end

  defp normalized_event_index(events) do
    {index, _counts} =
      events
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}}, fn {event, position}, {index, counts} ->
        canonical = canonical_normalized_event(event)
        base_identity = normalized_event_base_identity(canonical)
        occurrence = Map.get(counts, base_identity, 0) + 1
        key = {base_identity, occurrence}

        entry = %{
          identity: base_identity,
          occurrence: occurrence,
          index: position,
          canonical: canonical
        }

        {Map.put(index, key, entry), Map.put(counts, base_identity, occurrence)}
      end)

    index
  end

  defp normalized_event_base_identity(%{"event_seq" => event_seq}) when is_integer(event_seq) do
    {:event_seq, event_seq}
  end

  defp normalized_event_base_identity(%{"event_seq" => event_seq}) when is_binary(event_seq) do
    case Integer.parse(String.trim(event_seq)) do
      {integer, ""} -> {:event_seq, integer}
      _parse_error -> {:fingerprint, canonical_event_fingerprint(%{"event_seq" => event_seq})}
    end
  end

  defp normalized_event_base_identity(canonical) do
    {:fingerprint, canonical_event_fingerprint(canonical)}
  end

  defp canonical_event_fingerprint(canonical) do
    canonical
    |> Ourocode.Json.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp comparison_event_summary(index, key) do
    entry = Map.fetch!(index, key)

    %{
      identity: normalized_event_identity_report(key),
      event_index: entry.index,
      event: entry.canonical
    }
  end

  defp normalized_event_identity_report({{kind, value}, occurrence}) do
    %{
      kind: kind,
      value: value,
      occurrence: occurrence
    }
  end

  defp differing_normalized_fields(left, right) when is_map(left) and is_map(right) do
    left_keys = left |> Map.keys() |> MapSet.new()
    right_keys = right |> Map.keys() |> MapSet.new()

    left_keys
    |> MapSet.union(right_keys)
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.reject(fn key -> Map.get(left, key) == Map.get(right, key) end)
  end

  defp differing_normalized_fields(_left, _right), do: [:root]

  defp canonical_normalized_event(%LifecycleEvent{} = event) do
    event
    |> Map.from_struct()
    |> canonical_normalized_event()
  end

  defp canonical_normalized_event(%{} = event) do
    event
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      normalized_key = to_string(key)

      cond do
        MapSet.member?(@normalized_event_diagnostic_keys, normalized_key) ->
          acc

        true ->
          case canonical_normalized_value(value) do
            nil -> acc
            canonical_value -> Map.put(acc, normalized_key, canonical_value)
          end
      end
    end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Map.new()
  end

  defp canonical_normalized_value(%LifecycleEvent{} = event),
    do: canonical_normalized_event(event)

  defp canonical_normalized_value(%{} = map), do: canonical_normalized_event(map)

  defp canonical_normalized_value(list) when is_list(list) do
    Enum.map(list, &canonical_normalized_value/1)
  end

  defp canonical_normalized_value(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> canonical_normalized_value()
  end

  defp canonical_normalized_value(nil), do: nil
  defp canonical_normalized_value(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical_normalized_value(value), do: value

  defp event_type(entry) do
    map_value(entry, :type) || map_value(entry, :event_type)
  end

  defp entry_status(entry), do: map_value(entry, :status)

  defp entry_child_id(entry) when is_map(entry) do
    map_value(entry, :child_id) ||
      entry_external_id(entry, "childID") ||
      entry_external_id(entry, "child_id") ||
      payload_child_id(entry) ||
      raw_event_child_id(entry)
  end

  defp entry_child_id(_entry), do: nil

  defp entry_external_id(entry, key) do
    case map_value(entry, :external_ids) do
      external_ids when is_map(external_ids) ->
        Map.get(external_ids, key) || Map.get(external_ids, external_id_atom_key(key))

      _external_ids ->
        nil
    end
  end

  defp external_id_atom_key("childID"), do: :childID
  defp external_id_atom_key("child_id"), do: :child_id

  defp payload_child_id(entry) do
    case map_value(entry, :payload) do
      payload when is_map(payload) ->
        Map.get(payload, "childID") || Map.get(payload, :childID) ||
          Map.get(payload, "child_id") || Map.get(payload, :child_id)

      _payload ->
        nil
    end
  end

  defp raw_event_child_id(entry) do
    params =
      entry
      |> map_value(:raw_event)
      |> raw_event_data()
      |> raw_event_params()

    if is_map(params) do
      Map.get(params, "childID") || Map.get(params, :childID) ||
        Map.get(params, "child_id") || Map.get(params, :child_id)
    end
  end

  defp raw_event_data(raw_event) when is_map(raw_event) do
    Map.get(raw_event, "data") || Map.get(raw_event, :data) || raw_event
  end

  defp raw_event_data(_raw_event), do: nil

  defp raw_event_params(data) when is_map(data) do
    Map.get(data, "params") || Map.get(data, :params) || data
  end

  defp raw_event_params(_data), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp child_event_identity_value(entry) do
    case child_event_identity(entry) do
      {:ok, child_event_id} -> child_event_id
      {:error, _reason} -> nil
    end
  end

  defp child_runtime_seq(entry) when is_map(entry) do
    entry
    |> child_runtime_seq_candidates()
    |> Enum.find_value(&integer_value/1)
  end

  defp child_runtime_seq(_entry), do: nil

  defp child_runtime_seq_candidates(entry) do
    [
      map_value(entry, :runtime_seq),
      map_value(entry, :rendered_event_seq),
      map_value(map_value(entry, :payload), :runtime_seq),
      map_value(map_value(entry, :payload), :seq),
      map_value(map_value(entry, :payload), :event_seq),
      map_value(map_value(entry, :stream_cursor), :runtime_seq),
      map_value(map_value(entry, :stream_cursor), :seq)
    ]
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _parse_error -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp identity_component(name, value) do
    value = identity_component_value(value)
    Atom.to_string(name) <> "=" <> Integer.to_string(byte_size(value)) <> ":" <> value
  end

  defp identity_component_value(nil), do: "none"
  defp identity_component_value(value) when is_atom(value), do: Atom.to_string(value)
  defp identity_component_value(value), do: to_string(value)

  defp rendered_sequence_records(rendered_pane) do
    sequences =
      Map.get(rendered_pane, :rendered_sequences) || Map.get(rendered_pane, "rendered_sequences") ||
        []

    stream_entries = rendered_stream_entries(rendered_pane)

    sequences
    |> Enum.with_index()
    |> Enum.map(fn {sequence, index} ->
      stream_entry = Enum.at(stream_entries, index)

      %{
        type: :rendered_sequence_entry,
        source: :pane_model,
        pane_id:
          Map.get(sequence, :pane_id) || Map.get(sequence, "pane_id") || pane_id(rendered_pane),
        child_id:
          Map.get(sequence, :child_id) || Map.get(sequence, "child_id") || child_id(rendered_pane),
        child_event_id:
          Map.get(sequence, :child_event_id) || Map.get(sequence, "child_event_id") ||
            child_event_id(stream_entry),
        rendered_sequence_id: Map.get(sequence, :id) || Map.get(sequence, "id"),
        rendered_event_seq: Map.get(sequence, :event_seq) || Map.get(sequence, "event_seq"),
        runtime_seq: Map.get(sequence, :runtime_seq) || Map.get(sequence, "runtime_seq"),
        rendered_index: Map.get(sequence, :rendered_index) || Map.get(sequence, "rendered_index"),
        rendered_sequence: sequence,
        payload: stream_entry,
        occurred_at_ms: occurred_at_ms(stream_entry, rendered_pane)
      }
    end)
  end

  defp rendered_stream_entries(rendered_pane) do
    pane_state =
      Map.get(rendered_pane, :pane_state) || Map.get(rendered_pane, "pane_state") || %{}

    case Map.get(pane_state, :stream_entries) || Map.get(pane_state, "stream_entries") do
      entries when is_list(entries) -> entries
      _entries -> []
    end
  end

  defp pane_id(rendered_pane), do: Map.get(rendered_pane, :id) || Map.get(rendered_pane, "id")

  defp child_id(rendered_pane),
    do: Map.get(rendered_pane, :child_id) || Map.get(rendered_pane, "child_id")

  defp occurred_at_ms(%{} = stream_entry, rendered_pane) do
    Map.get(stream_entry, :occurred_at_ms) ||
      Map.get(stream_entry, "occurred_at_ms") ||
      Map.get(rendered_pane, :updated_at_ms) ||
      Map.get(rendered_pane, "updated_at_ms")
  end

  defp occurred_at_ms(_stream_entry, rendered_pane) do
    Map.get(rendered_pane, :updated_at_ms) || Map.get(rendered_pane, "updated_at_ms")
  end

  defp child_event_id(%{} = stream_entry) do
    Map.get(stream_entry, :child_event_id) || Map.get(stream_entry, "child_event_id")
  end

  defp child_event_id(_stream_entry), do: nil

  defp record_for_append(path, event) do
    record = json_safe(event)

    with {:ok, entries} <- read_existing_entries(path),
         {:ok, event_seq} <- event_seq_for_append(record, entries) do
      {:ok, Map.put(record, "event_seq", event_seq)}
    end
  end

  defp read_existing_entries(path) do
    case read(path) do
      {:ok, entries} -> {:ok, entries}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp event_seq_for_append(%{"event_seq" => event_seq}, entries) when is_integer(event_seq) do
    case entries do
      [] ->
        {:ok, event_seq}

      _entries ->
        expected_event_seq = next_event_seq_from_entries(entries)

        if event_seq == expected_event_seq do
          {:ok, event_seq}
        else
          {:error, {:event_seq_gap, expected_event_seq, event_seq}}
        end
    end
  end

  defp event_seq_for_append(%{"event_seq" => event_seq}, _entries) do
    {:error, {:invalid_event_seq, event_seq}}
  end

  defp event_seq_for_append(_record, entries), do: {:ok, next_event_seq_from_entries(entries)}

  defp next_event_seq_from_entries(entries) do
    entries
    |> Enum.map(&(Map.get(&1, :event_seq) || Map.get(&1, "event_seq")))
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> 1
      event_seqs -> Enum.max(event_seqs) + 1
    end
  end

  defp json_safe(%LifecycleEvent{} = event), do: event |> Map.from_struct() |> json_safe()

  defp json_safe(%{} = map) do
    Map.new(map, fn
      {key, value} when key in [:raw_event, "raw_event"] ->
        {to_string(key), json_safe_raw_event(value)}

      {key, value} ->
        {to_string(key), json_safe(value)}
    end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_boolean(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(value), do: value

  defp json_safe_raw_event(value) when is_atom(value) do
    %{
      @raw_event_encoded_value_marker => true,
      "type" => "atom",
      "value" => Atom.to_string(value)
    }
  end

  defp json_safe_raw_event(value) when is_tuple(value) do
    %{
      @raw_event_encoded_value_marker => true,
      "type" => "tuple",
      "value" => value |> Tuple.to_list() |> json_safe_raw_event()
    }
  end

  defp json_safe_raw_event(%{} = map), do: json_safe_raw_event_map(map)
  defp json_safe_raw_event(list) when is_list(list), do: Enum.map(list, &json_safe_raw_event/1)
  defp json_safe_raw_event(value), do: json_safe(value)

  defp json_safe_raw_event_map(map) do
    if Enum.all?(map, fn {key, _value} -> is_binary(key) end) do
      Map.new(map, fn {key, value} -> {key, json_safe_raw_event(value)} end)
    else
      %{
        @raw_event_encoded_map_marker => true,
        @raw_event_encoded_map_entries =>
          Enum.map(map, fn {key, value} ->
            %{
              "key" => json_safe_raw_event_key(key),
              "value" => json_safe_raw_event(value)
            }
          end)
      }
    end
  end

  defp json_safe_raw_event_key(key) when is_binary(key), do: %{"type" => "string", "value" => key}

  defp json_safe_raw_event_key(key) when is_atom(key),
    do: %{"type" => "atom", "value" => Atom.to_string(key)}

  defp json_safe_raw_event_key(key) when is_tuple(key),
    do: %{"type" => "tuple", "value" => key |> Tuple.to_list() |> json_safe_raw_event()}

  defp json_safe_raw_event_key(key), do: %{"type" => "term", "value" => inspect(key)}

  defp restore(%{} = map) do
    Map.new(map, fn {key, value} ->
      restored_key = restore_top_level_key(key)
      {restored_key, restore_value(restored_key, value)}
    end)
  end

  defp restore_top_level_key(key), do: Map.get(@known_top_level_keys, key, key)

  defp restore_value(key, value)
       when key in [
              :type,
              :event_type,
              :transport,
              :question_kind,
              :source,
              :change,
              :reason,
              :relevance,
              :reload_boundary,
              :input_kind,
              :steering_target
            ],
       do: restore_known_atom(value)

  defp restore_value(:raw_event, value), do: restore_raw_event(value)
  defp restore_value(:external_ids, value), do: restore_external_ids(value)
  defp restore_value(_key, value), do: restore_nested(value)

  defp restore_external_ids(%{} = map) do
    restored = restore_nested(map)

    restored
    |> maybe_put_alias(:childID, Map.get(restored, "childID"))
    |> maybe_put_alias(:child_id, Map.get(restored, "child_id"))
    |> maybe_put_alias(:session_id, Map.get(restored, "session_id"))
    |> maybe_put_alias(:thread_id, Map.get(restored, "thread_id"))
    |> maybe_put_alias(:job_id, Map.get(restored, "job_id"))
    |> maybe_put_alias(:execution_id, Map.get(restored, "execution_id"))
    |> maybe_put_alias(:lineage_id, Map.get(restored, "lineage_id"))
  end

  defp restore_external_ids(value), do: restore_nested(value)

  defp maybe_put_alias(map, _key, nil), do: map
  defp maybe_put_alias(map, key, value), do: Map.put_new(map, key, value)

  defp restore_nested(%{} = map) do
    Map.new(map, fn {key, value} -> {key, restore_nested(value)} end)
  end

  defp restore_nested(list) when is_list(list), do: Enum.map(list, &restore_nested/1)
  defp restore_nested(value), do: value

  defp restore_raw_event(%{
         @raw_event_encoded_map_marker => true,
         @raw_event_encoded_map_entries => entries
       })
       when is_list(entries) do
    Map.new(entries, fn
      %{"key" => key, "value" => value} ->
        {restore_raw_event_key(key), restore_raw_event(value)}

      entry ->
        {entry, nil}
    end)
  end

  defp restore_raw_event(%{
         @raw_event_encoded_value_marker => true,
         "type" => "atom",
         "value" => value
       })
       when is_binary(value) do
    String.to_atom(value)
  end

  defp restore_raw_event(%{
         @raw_event_encoded_value_marker => true,
         "type" => "tuple",
         "value" => value
       })
       when is_list(value) do
    value |> Enum.map(&restore_raw_event/1) |> List.to_tuple()
  end

  defp restore_raw_event(%{} = map) do
    Map.new(map, fn {key, value} -> {key, restore_raw_event(value)} end)
  end

  defp restore_raw_event(list) when is_list(list), do: Enum.map(list, &restore_raw_event/1)
  defp restore_raw_event(value), do: restore_nested(value)

  defp restore_raw_event_key(%{"type" => "string", "value" => value}) when is_binary(value),
    do: value

  defp restore_raw_event_key(%{"type" => "atom", "value" => value}) when is_binary(value),
    do: String.to_atom(value)

  defp restore_raw_event_key(%{"type" => "tuple", "value" => value}) when is_list(value),
    do: value |> Enum.map(&restore_raw_event/1) |> List.to_tuple()

  defp restore_raw_event_key(%{"value" => value}), do: value
  defp restore_raw_event_key(value), do: value

  defp restore_known_atom(value) when is_binary(value), do: Map.get(@known_atoms, value, value)
  defp restore_known_atom(value), do: value
end
