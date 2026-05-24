defmodule Ourocode.Journal.CodecTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.Codec

  test "encodes normalized events into JSON-safe records and restores known fields" do
    record =
      Codec.encode(%{
        type: :plugin_config_reloaded,
        event_type: :plugin_config_reloaded,
        transport: :streamable_http,
        external_ids: %{"child_id" => "child-1", "job_id" => "job-1"},
        nested: %{status: :ok}
      })

    assert record == %{
             "type" => "plugin_config_reloaded",
             "event_type" => "plugin_config_reloaded",
             "transport" => "streamable_http",
             "external_ids" => %{"child_id" => "child-1", "job_id" => "job-1"},
             "nested" => %{"status" => "ok"}
           }

    assert Codec.decode(record) == %{
             "nested" => %{"status" => "ok"},
             type: :plugin_config_reloaded,
             event_type: :plugin_config_reloaded,
             transport: :streamable_http,
             external_ids: %{
               "child_id" => "child-1",
               "job_id" => "job-1",
               child_id: "child-1",
               job_id: "job-1"
             }
           }
  end

  test "preserves raw event maps with atom and tuple keys without creating atoms" do
    raw_event = %{
      :method => :notification,
      {:params, :child} => %{child_id: "child-1", status: :completed},
      "string-key" => {:tuple, :value}
    }

    record = Codec.encode(%{type: :child_stream_event, raw_event: raw_event})
    restored = Codec.decode(record)

    assert restored.type == :child_stream_event

    assert restored.raw_event == %{
             :method => :notification,
             {:params, :child} => %{child_id: "child-1", status: :completed},
             "string-key" => {:tuple, :value}
           }
  end

  test "leaves unknown atom names as strings on decode" do
    assert Codec.decode(%{"type" => "not_existing_atom_for_codec_test"}) == %{
             type: "not_existing_atom_for_codec_test"
           }
  end
end
