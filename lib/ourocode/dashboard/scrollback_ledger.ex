defmodule Ourocode.Dashboard.ScrollbackLedger do
  @moduledoc """
  Projects pane stream events into a selectable scrollback ledger.

  The ledger is intentionally data-only. Terminal and dashboard renderers can
  decide how to draw selection, expansion, and detail viewers without changing
  the MCP/ACP stream ownership model.
  """

  alias Ourocode.Json

  @redacted "[redacted]"
  @secret_key_pattern ~r/(token|secret|password|authorization|bearer|api[_-]?key|access[_-]?key|refresh[_-]?token|id[_-]?token)/i
  @secret_query_pattern ~r/([?&][^=]*(?:token|secret|password|api[_-]?key|key)[^=]*=)[^&#\s]+/i

  @spec from_child_pane(map()) :: map()
  def from_child_pane(%{kind: :child_session} = pane) do
    entries = stream_entries(pane)

    blocks =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, index} -> block_for_entry(pane, entry, index) end)

    %{
      kind: :scrollback_ledger,
      pane_id: Map.get(pane, :id),
      owner_kind: :child_session,
      owner_id: Map.get(pane, :child_id),
      parent_call_id: Map.get(pane, :parent_call_id),
      selectable?: true,
      block_count: length(blocks),
      selected_block_id: selected_block_id(pane, blocks),
      blocks: blocks
    }
  end

  def from_child_pane(_pane) do
    %{
      kind: :scrollback_ledger,
      owner_kind: :unknown,
      selectable?: true,
      block_count: 0,
      selected_block_id: nil,
      blocks: []
    }
  end

  @spec render_block_line(map()) :: String.t()
  def render_block_line(%{status: status, title: title, summary: summary, collapsed?: collapsed?}) do
    indicator = if collapsed?, do: "+", else: "-"
    summary = if summary in [nil, ""], do: "(no output)", else: summary

    [
      indicator,
      "[" <> to_string(status) <> "]",
      title,
      summary
    ]
    |> Enum.join(" ")
  end

  def render_block_line(_block), do: "+ [unknown] event (no output)"

  defp block_for_entry(pane, entry, index) do
    payload = payload(entry)
    kind = block_kind(entry, payload)
    status = status(payload, kind)
    title = title(kind, entry, payload)
    summary = summary(kind, entry, payload)
    redacted_payload = redact(payload)

    %{
      id: block_id(pane, entry, index),
      kind: kind,
      title: title,
      status: status,
      collapsed?: collapsed?(kind),
      selectable?: true,
      pane_id: Map.get(pane, :id),
      owner_id: Map.get(pane, :child_id),
      parent_call_id: Map.get(pane, :parent_call_id),
      child_event_id: value(entry, :child_event_id),
      event_seq: value(entry, :event_seq),
      runtime_seq: value(entry, :runtime_seq),
      tool_call_id: tool_call_id(payload),
      summary: summary,
      detail_preview: detail_preview(redacted_payload),
      payload: redacted_payload
    }
  end

  defp block_id(pane, entry, index) do
    cond do
      present?(value(entry, :rendered_sequence_id)) ->
        "ledger:" <> value(entry, :rendered_sequence_id)

      present?(value(entry, :child_event_id)) ->
        "ledger:child-event:" <> value(entry, :child_event_id)

      present?(tool_call_id(payload(entry))) ->
        [
          "ledger",
          Map.get(pane, :id, "pane"),
          "tool",
          tool_call_id(payload(entry)),
          index
        ]
        |> Enum.join(":")

      true ->
        [
          "ledger",
          Map.get(pane, :id, "pane"),
          "event=#{value(entry, :event_seq) || "none"}",
          "runtime=#{value(entry, :runtime_seq) || "none"}",
          "index=#{index}"
        ]
        |> Enum.join(":")
    end
  end

  defp selected_block_id(pane, blocks) do
    selected =
      get_in(pane, [:pane_state, :selected_ledger_block_id]) ||
        get_in(pane, [:pane_state, "selected_ledger_block_id"])

    cond do
      present?(selected) and Enum.any?(blocks, &(&1.id == selected)) -> selected
      blocks == [] -> nil
      true -> List.last(blocks).id
    end
  end

  defp block_kind(entry, payload) do
    cond do
      permission_payload?(payload) -> :permission
      diff_payload?(payload) -> :diff
      terminal_payload?(payload) -> :terminal
      tool_payload?(payload) -> :tool_call
      media_payload?(entry, payload) -> :media
      message_payload?(entry, payload) -> :message
      true -> :event
    end
  end

  defp title(:permission, _entry, payload),
    do: "Permission " <> string_or(payload, ["tool_name", :tool_name, "name", :name], "request")

  defp title(:diff, _entry, payload),
    do: "Diff " <> string_or(payload, ["file_path", :file_path, "path", :path], "update")

  defp title(:terminal, _entry, payload),
    do:
      "Run " <>
        string_or(payload, ["command", :command, "display_command", :display_command], "terminal")

  defp title(:tool_call, _entry, payload),
    do: "Tool " <> string_or(payload, tool_name_keys(), "call")

  defp title(:media, _entry, _payload), do: "Media"
  defp title(:message, _entry, _payload), do: "Message"
  defp title(:event, entry, _payload), do: "Event " <> to_string(value(entry, :type) || "stream")

  defp summary(:permission, _entry, payload),
    do:
      string_or(
        payload,
        ["description", :description, "preview", :preview, "reason", :reason],
        "waiting for decision"
      )

  defp summary(:diff, entry, payload),
    do:
      compact(
        string_or(
          payload,
          ["summary", :summary, "patch", :patch, "diff", :diff],
          stream_text(entry) || "file changes"
        )
      )

  defp summary(:terminal, entry, payload),
    do:
      compact(
        string_or(
          payload,
          ["output", :output, "stdout", :stdout, "stderr", :stderr],
          stream_text(entry) || "running"
        )
      )

  defp summary(:tool_call, entry, payload),
    do:
      compact(
        string_or(
          payload,
          ["summary", :summary, "result", :result, "output", :output],
          stream_text(entry) || argument_summary(payload)
        )
      )

  defp summary(:media, entry, _payload),
    do: Enum.join(value(entry, :media_placeholders) || [], " ")

  defp summary(:message, entry, _payload), do: compact(stream_text(entry) || "")

  defp summary(:event, entry, payload),
    do:
      compact(
        stream_text(entry) ||
          string_or(payload, ["status", :status, "event", :event], "lifecycle event")
      )

  defp collapsed?(:message), do: false
  defp collapsed?(:media), do: false
  defp collapsed?(_kind), do: true

  defp status(payload, :permission) do
    if present?(string_any(payload, ["outcome", :outcome])), do: :completed, else: :pending
  end

  defp status(payload, _kind) do
    payload
    |> string_any(["status", :status, "state", :state, "phase", :phase])
    |> normalize_status()
  end

  defp normalize_status(nil), do: :streaming
  defp normalize_status(status) when status in ["pending", "queued"], do: :pending

  defp normalize_status(status) when status in ["in_progress", "working", "running", "streaming"],
    do: :streaming

  defp normalize_status(status)
       when status in ["completed", "complete", "done", "success", "succeeded"], do: :completed

  defp normalize_status(status) when status in ["failed", "error", "cancelled", "timeout"],
    do: :failed

  defp normalize_status(_status), do: :streaming

  defp permission_payload?(payload) do
    present?(string_any(payload, ["outcome", :outcome])) or
      list_present?(value_any(payload, ["options", :options])) or
      present?(
        string_any(payload, ["permission", :permission, "permission_mode", :permission_mode])
      )
  end

  defp diff_payload?(payload) do
    present?(
      string_any(payload, [
        "diff",
        :diff,
        "patch",
        :patch,
        "old_string",
        :old_string,
        "new_string",
        :new_string
      ])
    ) or
      map_present?(value_any(payload, ["edits", :edits]))
  end

  defp terminal_payload?(payload) do
    present?(
      string_any(payload, [
        "command",
        :command,
        "display_command",
        :display_command,
        "stdout",
        :stdout,
        "stderr",
        :stderr
      ])
    ) or
      present?(string_any(payload, ["terminal_id", :terminal_id, "terminalId", :terminalId]))
  end

  defp tool_payload?(payload) do
    present?(tool_call_id(payload)) or present?(string_any(payload, tool_name_keys()))
  end

  defp media_payload?(entry, payload) do
    list_present?(value(entry, :media_placeholders)) or
      list_present?(
        value_any(payload, ["images", :images, "attachments", :attachments, "media", :media])
      )
  end

  defp message_payload?(entry, payload) do
    present?(stream_text(entry)) or
      present?(string_any(payload, ["message", :message, "text", :text]))
  end

  defp argument_summary(payload) do
    payload
    |> value_any([
      "arguments",
      :arguments,
      "tool_input",
      :tool_input,
      "tool_args_json",
      :tool_args_json
    ])
    |> case do
      nil -> "arguments"
      value when is_binary(value) -> value
      value -> inspect(redact(value), limit: 20, printable_limit: 200)
    end
  end

  defp detail_preview(payload) when payload == %{}, do: "{}"

  defp detail_preview(payload) do
    payload
    |> Json.encode!()
    |> IO.iodata_to_binary()
    |> compact(500)
  rescue
    _error -> payload |> inspect(limit: 40, printable_limit: 500) |> compact(500)
  end

  defp payload(entry) when is_map(entry) do
    case value(entry, :payload) do
      payload when is_map(payload) -> payload
      _payload -> %{}
    end
  end

  defp payload(_entry), do: %{}

  defp stream_entries(%{pane_state: pane_state}) when is_map(pane_state) do
    case Map.get(pane_state, :stream_entries, []) do
      entries when is_list(entries) -> entries
      _entries -> []
    end
  end

  defp stream_entries(_pane), do: []

  defp stream_text(entry) do
    string_any(entry, [:token, "token", :delta, "delta", :content, "content"])
  end

  defp tool_call_id(payload) do
    string_any(payload, [
      "tool_call_id",
      :tool_call_id,
      "toolCallId",
      :toolCallId,
      "tool_use_id",
      :tool_use_id,
      "id",
      :id
    ])
  end

  defp tool_name_keys do
    [
      "tool_name",
      :tool_name,
      "toolName",
      :toolName,
      "name",
      :name,
      "effective_tool_name",
      :effective_tool_name
    ]
  end

  defp string_or(payload, keys, default) do
    case string_any(payload, keys) do
      value when is_binary(value) and value != "" -> redact_string(value)
      _value -> default
    end
  end

  defp string_any(map, keys) when is_map(map) do
    keys
    |> Enum.find_value(fn key ->
      case Map.get(map, key) do
        value when is_binary(value) -> String.trim(value)
        value when is_integer(value) -> Integer.to_string(value)
        value when is_float(value) -> Float.to_string(value)
        value when is_boolean(value) -> to_string(value)
        _value -> nil
      end
    end)
  end

  defp string_any(_map, _keys), do: nil

  defp value_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp value_any(_map, _keys), do: nil

  defp value(entry, key) when is_map(entry) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp value(_entry, _key), do: nil

  defp redact(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if secret_key?(key) do
        {key, @redacted}
      else
        {key, redact(value)}
      end
    end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  defp redact(value) when is_binary(value), do: redact_string(value)
  defp redact(value), do: value

  defp redact_string(value) do
    Regex.replace(@secret_query_pattern, value, "\\1" <> @redacted)
  end

  defp secret_key?(key), do: Regex.match?(@secret_key_pattern, to_string(key))

  defp compact(value, limit \\ 120)
  defp compact(nil, _limit), do: ""

  defp compact(value, limit) when is_binary(value) do
    value =
      value
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "..."
    else
      value
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp list_present?(value) when is_list(value), do: value != []
  defp list_present?(_value), do: false

  defp map_present?(value) when is_map(value), do: map_size(value) > 0
  defp map_present?(value) when is_list(value), do: value != []
  defp map_present?(_value), do: false
end
