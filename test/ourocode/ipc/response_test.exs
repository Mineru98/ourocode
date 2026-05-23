defmodule Ourocode.IPC.ResponseTest do
  use ExUnit.Case, async: true

  alias Ourocode.IPC.Envelope
  alias Ourocode.IPC.Error
  alias Ourocode.IPC.Request
  alias Ourocode.IPC.Response

  test "defines a successful IPC/RPC response payload correlated to a request id" do
    assert {:ok,
            %Envelope{
              version: 1,
              message_id: "res-1",
              message_type: "ipc.rpc.response",
              payload: %{
                "request_id" => "req-1",
                "status" => "ok",
                "result" => %{"matches" => [%{"path" => "lib/ourocode.ex"}]}
              },
              metadata: %{"rust_worker" => "scanner"}
            } = envelope} =
             Response.envelope(
               " res-1 ",
               " req-1 ",
               :ok,
               %{"matches" => [%{"path" => "lib/ourocode.ex"}]},
               nil,
               %{"rust_worker" => "scanner"}
             )

    assert Response.message_type() == "ipc.rpc.response"

    assert {:ok,
            %Response{
              message_id: "res-1",
              request_id: "req-1",
              status: "ok",
              result: %{"matches" => [%{"path" => "lib/ourocode.ex"}]},
              error: nil,
              metadata: %{"rust_worker" => "scanner"}
            }} = Response.from_envelope(envelope)
  end

  test "builds a response correlated from a request struct" do
    {:ok, request} = Request.new("req-2", "helper.diff", "run", %{"left" => "a", "right" => "b"})

    assert {:ok,
            %Response{
              message_id: "res-2",
              request_id: "req-2",
              status: "ok",
              result: %{"patch" => "@@"}
            }} = Response.ok_for_request("res-2", request, %{"patch" => "@@"})
  end

  test "validates decoded wire response maps" do
    wire = %{
      "version" => Envelope.current_version(),
      "message_id" => "res-3",
      "message_type" => Response.message_type(),
      "payload" => %{
        "request_id" => "req-3",
        "status" => "ok",
        "result" => %{"indexed" => 12}
      }
    }

    assert {:ok,
            %Response{
              message_id: "res-3",
              request_id: "req-3",
              status: "ok",
              result: %{"indexed" => 12},
              error: nil,
              metadata: %{}
            }} = Response.from_envelope(wire)
  end

  test "round trips through the project JSON codec" do
    {:ok, envelope} = Response.envelope("res-4", "req-4", "ok", %{"pid" => 42})

    encoded = Envelope.encode!(envelope) |> IO.iodata_to_binary()

    assert {:ok, ^envelope} = Envelope.decode(encoded)

    assert {:ok, %Response{request_id: "req-4", result: %{"pid" => 42}}} =
             Response.from_envelope(envelope)
  end

  test "deserializes successful Rust helper IPC response JSON messages" do
    {:ok, envelope} =
      Response.envelope(
        "res-deser-1",
        "req-deser-1",
        :ok,
        %{
          "worker" => "parser",
          "items" => [%{"path" => "lib/ourocode.ex", "kind" => "module"}]
        },
        nil,
        %{"rust_worker" => "parser", "runtime_source" => "ourocode"}
      )

    encoded = Envelope.encode!(envelope) |> IO.iodata_to_binary()

    assert {:ok,
            %Response{
              message_id: "res-deser-1",
              request_id: "req-deser-1",
              status: "ok",
              result: %{
                "worker" => "parser",
                "items" => [%{"path" => "lib/ourocode.ex", "kind" => "module"}]
              },
              error: nil,
              metadata: %{"rust_worker" => "parser", "runtime_source" => "ourocode"}
            }} = Response.deserialize(encoded)
  end

  test "deserializes newline-delimited Rust helper IPC response frames" do
    {:ok, envelope} =
      Response.envelope(
        "res-deser-2",
        "req-deser-2",
        :error,
        %{},
        %{
          "code" => "worker_timeout",
          "message" => "helper timed out",
          "detail" => %{"elapsed_ms" => 5_001}
        }
      )

    frame = [Envelope.encode!(envelope), "\r\n"] |> IO.iodata_to_binary()

    assert {:ok,
            %Response{
              message_id: "res-deser-2",
              request_id: "req-deser-2",
              status: "error",
              result: %{},
              error: %{
                "code" => "worker_timeout",
                "message" => "helper timed out",
                "detail" => %{"elapsed_ms" => 5_001}
              }
            }} = Response.deserialize_line(frame)
  end

  test "deserialization rejects malformed JSON and invalid Rust helper response envelopes" do
    assert {:error, {:invalid_value, "not-json"}} = Response.deserialize("not-json")
    assert {:error, {:invalid_field, "message", :not_binary}} = Response.deserialize(:not_binary)

    assert {:error, {:invalid_field, "line", :not_binary}} =
             Response.deserialize_line(:not_binary)

    {:ok, request_envelope} = Request.envelope("req-deser-3", "helper.scan", "run")
    encoded_request = Envelope.encode!(request_envelope) |> IO.iodata_to_binary()

    assert {:error, {:invalid_message_type, "ipc.rpc.request"}} =
             Response.deserialize(encoded_request)

    {:ok, response_envelope} = Response.envelope("res-deser-3", "req-deser-3", :ok, %{})
    encoded_response = Envelope.encode!(response_envelope) |> IO.iodata_to_binary()

    assert {:error, {:trailing_data, "{\"version\":1}"}} =
             Response.deserialize(encoded_response <> ~s({"version":1}))
  end

  test "defines an error response with a validated error payload" do
    assert {:ok,
            %Envelope{
              message_id: "res-5",
              payload: %{
                "request_id" => "req-5",
                "status" => "error",
                "error" => %{"code" => "worker_timeout", "message" => "helper timed out"}
              }
            } = envelope} =
             Response.envelope(
               "res-5",
               "req-5",
               :error,
               %{},
               %{"code" => "worker_timeout", "message" => "helper timed out"}
             )

    assert {:ok,
            %Response{
              request_id: "req-5",
              status: "error",
              result: %{},
              error: %{"code" => "worker_timeout", "message" => "helper timed out"}
            }} = Response.from_envelope(envelope)
  end

  test "normalizes structured IPC/RPC error details in response payloads" do
    {:ok, error} =
      Error.new("worker_exit", "helper exited", %{
        "exit_status" => 2,
        "stderr_tail" => "bad args"
      })

    assert {:ok,
            %Envelope{
              payload: %{
                "request_id" => "req-5b",
                "status" => "error",
                "error" => %{
                  "code" => "worker_exit",
                  "message" => "helper exited",
                  "detail" => %{"exit_status" => 2, "stderr_tail" => "bad args"}
                }
              }
            } = envelope} = Response.envelope("res-5b", "req-5b", :error, %{}, error)

    assert {:ok,
            %Response{
              request_id: "req-5b",
              status: "error",
              error: %{
                "code" => "worker_exit",
                "message" => "helper exited",
                "detail" => %{"exit_status" => 2, "stderr_tail" => "bad args"}
              }
            }} = Response.from_envelope(envelope)
  end

  test "rejects missing request correlation and invalid result payloads" do
    assert {:error, {:missing_required_field, "request_id"}} =
             Response.from_payload(%{"status" => "ok", "result" => %{}}, "res-6")

    assert {:error, {:missing_required_field, "result"}} =
             Response.from_payload(%{"request_id" => "req-6", "status" => "ok"}, "res-6")

    assert {:error, {:invalid_field, "request_id", " "}} =
             Response.from_payload(
               %{"request_id" => " ", "status" => "ok", "result" => %{}},
               "res-6"
             )

    assert {:error, {:invalid_field, "result", []}} =
             Response.from_payload(
               %{"request_id" => "req-6", "status" => "ok", "result" => []},
               "res-6"
             )

    assert {:error, {:invalid_field, "status", "pending"}} =
             Response.from_payload(
               %{"request_id" => "req-6", "status" => "pending", "result" => %{}},
               "res-6"
             )
  end

  test "rejects invalid status-specific payload combinations" do
    assert {:error, {:invalid_field, "error", %{"code" => "unexpected"}}} =
             Response.new("res-7", "req-7", :ok, %{}, %{"code" => "unexpected"})

    assert {:error, {:missing_required_field, "error"}} =
             Response.new("res-7", "req-7", :error, %{}, nil)

    assert {:error, {:invalid_field, "error", "timeout"}} =
             Response.from_payload(
               %{"request_id" => "req-7", "status" => "error", "error" => "timeout"},
               "res-7"
             )

    assert {:error, {:missing_required_field, "message"}} =
             Response.from_payload(
               %{
                 "request_id" => "req-7",
                 "status" => "error",
                 "error" => %{"code" => "worker_timeout"}
               },
               "res-7"
             )
  end

  test "rejects wrong envelope message type before dispatch" do
    {:ok, envelope} = Envelope.new("res-8", Request.message_type(), %{})

    assert {:error, {:invalid_message_type, "ipc.rpc.request"}} =
             Response.from_envelope(envelope)
  end
end
