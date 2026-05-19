defmodule Ourocode.IPC.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Ourocode.IPC.Envelope

  test "builds the current shared IPC/RPC envelope schema" do
    assert {:ok,
            %Envelope{
              version: 1,
              message_id: "msg-1",
              message_type: "helper.scan.request",
              payload: %{"path" => "lib"},
              metadata: %{"rust_worker" => "scanner"}
            } = envelope} =
             Envelope.new(
               "msg-1",
               "helper.scan.request",
               %{"path" => "lib"},
               %{"rust_worker" => "scanner"}
             )

    assert Envelope.to_map(envelope) == %{
             "version" => Envelope.current_version(),
             "message_id" => "msg-1",
             "message_type" => "helper.scan.request",
             "payload" => %{"path" => "lib"},
             "metadata" => %{"rust_worker" => "scanner"}
           }
  end

  test "decodes a wire map with required version, message id, and message type fields" do
    wire = %{
      "version" => 1,
      "message_id" => " reply-1 ",
      "message_type" => "helper.scan.reply",
      "payload" => %{"matches" => []}
    }

    assert {:ok,
            %Envelope{
              version: 1,
              message_id: "reply-1",
              message_type: "helper.scan.reply",
              payload: %{"matches" => []},
              metadata: %{}
            }} = Envelope.from_map(wire)
  end

  test "round trips through the project JSON codec" do
    {:ok, envelope} = Envelope.new("msg-2", "helper.diff.request", %{"left" => "a"})

    encoded = Envelope.encode!(envelope) |> IO.iodata_to_binary()

    assert {:ok, ^envelope} = Envelope.decode(encoded)
  end

  test "rejects envelopes missing required schema fields" do
    assert {:error, {:missing_required_field, "version"}} =
             Envelope.from_map(%{"message_id" => "msg-1", "message_type" => "type"})

    assert {:error, {:missing_required_field, "message_id"}} =
             Envelope.from_map(%{"version" => 1, "message_type" => "type"})

    assert {:error, {:missing_required_field, "message_type"}} =
             Envelope.from_map(%{"version" => 1, "message_id" => "msg-1"})
  end

  test "rejects unsupported versions and invalid field types" do
    assert {:error, :unsupported_version} =
             Envelope.from_map(%{
               "version" => 2,
               "message_id" => "msg-1",
               "message_type" => "type"
             })

    assert {:error, {:invalid_field, "message_id", " "}} =
             Envelope.from_map(%{
               "version" => 1,
               "message_id" => " ",
               "message_type" => "type"
             })

    assert {:error, {:invalid_field, "message_type", 123}} =
             Envelope.from_map(%{
               "version" => 1,
               "message_id" => "msg-1",
               "message_type" => 123
             })

    assert {:error, {:invalid_field, "payload", []}} =
             Envelope.from_map(%{
               "version" => 1,
               "message_id" => "msg-1",
               "message_type" => "type",
               "payload" => []
             })
  end
end
