defmodule Ourocode.Dashboard.ParentMcpPaneMetadataTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ParentMcpPaneMetadata, as: Metadata

  test "normalizes metadata from atom and string keys" do
    metadata = %{
      "parent_call_id" => 42,
      "transport" => "streamable_http",
      "updated_at_ms" => "120",
      runtime_source: :synthetic,
      external_ids: %{session_id: "session-1"}
    }

    assert Metadata.string(metadata, :parent_call_id) == {:ok, "42"}
    assert Metadata.string(metadata, :runtime_source) == {:ok, "synthetic"}
    assert Metadata.transport(metadata) == {:ok, :streamable_http}
    assert Metadata.integer(metadata, :updated_at_ms) == 120
    assert Metadata.map_value(metadata, :external_ids, %{}) == %{session_id: "session-1"}
    assert Metadata.map_value(metadata, :stream_cursor, %{default?: true}) == %{default?: true}
  end

  test "rejects invalid required metadata and invalid normalizer values" do
    assert Metadata.string(%{parent_call_id: ""}, :parent_call_id) == :error
    assert Metadata.transport(%{transport: "websocket"}) == :error
    assert Metadata.integer(%{updated_at_ms: "12ms"}, :updated_at_ms) == nil
    assert Metadata.normalize_status("paused") == nil
    assert Metadata.normalize_transport("websocket") == nil
    assert Metadata.normalize_string("") == nil
  end
end
