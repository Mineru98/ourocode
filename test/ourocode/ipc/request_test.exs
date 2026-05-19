defmodule Ourocode.IPC.RequestTest do
  use ExUnit.Case, async: true

  alias Ourocode.IPC.Envelope
  alias Ourocode.IPC.Request

  test "defines the IPC/RPC request payload schema inside a shared envelope" do
    assert {:ok,
            %Envelope{
              version: 1,
              message_id: "req-1",
              message_type: "ipc.rpc.request",
              payload: %{
                "method" => "helper.scan",
                "action" => "start",
                "params" => %{"path" => "lib", "limit" => 50}
              },
              metadata: %{"rust_worker" => "scanner"}
            } = envelope} =
             Request.envelope(
               " req-1 ",
               " helper.scan ",
               " start ",
               %{"path" => "lib", "limit" => 50},
               %{"rust_worker" => "scanner"}
             )

    assert Request.message_type() == "ipc.rpc.request"

    assert {:ok,
            %Request{
              message_id: "req-1",
              method: "helper.scan",
              action: "start",
              params: %{"path" => "lib", "limit" => 50},
              metadata: %{"rust_worker" => "scanner"}
            }} = Request.from_envelope(envelope)
  end

  test "validates decoded wire request maps" do
    wire = %{
      "version" => Envelope.current_version(),
      "message_id" => "req-2",
      "message_type" => Request.message_type(),
      "payload" => %{
        "method" => "helper.diff",
        "action" => "run",
        "params" => %{"left" => "a", "right" => "b"}
      }
    }

    assert {:ok,
            %Request{
              message_id: "req-2",
              method: "helper.diff",
              action: "run",
              params: %{"left" => "a", "right" => "b"},
              metadata: %{}
            }} = Request.from_envelope(wire)
  end

  test "serializes validated requests to Rust helper IPC wire JSON" do
    assert {:ok, encoded} =
             Request.serialize(
               " req-serial-1 ",
               " helper.index ",
               " run ",
               %{"root" => "lib", "include" => ["*.ex"]},
               %{"rust_worker" => "indexer", "runtime_source" => "ourocode"}
             )

    assert is_binary(encoded)
    refute String.ends_with?(encoded, "\n")

    assert {:ok,
            %Envelope{
              version: 1,
              message_id: "req-serial-1",
              message_type: "ipc.rpc.request",
              payload: %{
                "method" => "helper.index",
                "action" => "run",
                "params" => %{"root" => "lib", "include" => ["*.ex"]}
              },
              metadata: %{"rust_worker" => "indexer", "runtime_source" => "ourocode"}
            } = envelope} = Envelope.decode(encoded)

    assert {:ok,
            %Request{
              message_id: "req-serial-1",
              method: "helper.index",
              action: "run",
              params: %{"root" => "lib", "include" => ["*.ex"]},
              metadata: %{"rust_worker" => "indexer", "runtime_source" => "ourocode"}
            }} = Request.from_envelope(envelope)
  end

  test "serializes request structs as newline-delimited IPC frames" do
    {:ok, request} =
      Request.new("req-serial-2", "helper.parser", "parse", %{"path" => "lib/ourocode.ex"})

    assert {:ok, frame} = Request.serialize_line(request)
    assert String.ends_with?(frame, "\n")

    encoded = String.trim_trailing(frame, "\n")

    assert {:ok,
            %Request{
              message_id: "req-serial-2",
              method: "helper.parser",
              action: "parse",
              params: %{"path" => "lib/ourocode.ex"}
            }} =
             encoded
             |> Envelope.decode()
             |> then(fn {:ok, envelope} -> Request.from_envelope(envelope) end)
  end

  test "serialization rejects invalid request fields before wire encoding" do
    assert {:error, {:invalid_field, "message_id", " "}} =
             Request.serialize(" ", "helper.scan", "run")

    assert {:error, {:invalid_field, "params", []}} =
             Request.serialize_line("req-serial-3", "helper.scan", "run", [])

    assert {:error, {:invalid_field, "method", nil}} =
             Request.serialize(%Request{message_id: "req-serial-4", method: nil, action: "run"})
  end

  test "rejects missing method/action and non-map params payloads" do
    assert {:error, {:missing_required_field, "method"}} =
             Request.from_payload(%{"action" => "run", "params" => %{}}, "req-3")

    assert {:error, {:missing_required_field, "action"}} =
             Request.from_payload(%{"method" => "helper.scan", "params" => %{}}, "req-3")

    assert {:error, {:invalid_field, "method", " "}} =
             Request.from_payload(%{"method" => " ", "action" => "run"}, "req-3")

    assert {:error, {:invalid_field, "action", 123}} =
             Request.from_payload(%{"method" => "helper.scan", "action" => 123}, "req-3")

    assert {:error, {:invalid_field, "params", []}} =
             Request.from_payload(%{"method" => "helper.scan", "action" => "run", "params" => []}, "req-3")
  end

  test "rejects wrong envelope message type before dispatch" do
    {:ok, envelope} = Envelope.new("req-4", "ipc.rpc.reply", %{})

    assert {:error, {:invalid_message_type, "ipc.rpc.reply"}} =
             Request.from_envelope(envelope)
  end
end
