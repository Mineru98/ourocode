defmodule Ourocode.IPC.ErrorTest do
  use ExUnit.Case, async: true

  alias Ourocode.IPC.Error

  test "defines the IPC/RPC error message schema with code and message" do
    assert {:ok,
            %Error{
              code: "worker_timeout",
              message: "helper timed out",
              detail: nil
            } = error} = Error.new(" worker_timeout ", " helper timed out ")

    assert Error.to_map(error) == %{
             "code" => "worker_timeout",
             "message" => "helper timed out"
           }
  end

  test "accepts optional structured detail fields" do
    assert {:ok,
            %Error{
              code: "worker_exit",
              message: "helper exited",
              detail: %{"exit_status" => 2, "stderr_tail" => "bad args"}
            } = error} =
             Error.from_map(%{
               "code" => " worker_exit ",
               "message" => " helper exited ",
               "detail" => %{"exit_status" => 2, "stderr_tail" => "bad args"}
             })

    assert Error.to_map(error) == %{
             "code" => "worker_exit",
             "message" => "helper exited",
             "detail" => %{"exit_status" => 2, "stderr_tail" => "bad args"}
           }
  end

  test "rejects missing required error fields" do
    assert {:error, {:missing_required_field, "code"}} =
             Error.from_map(%{"message" => "helper timed out"})

    assert {:error, {:missing_required_field, "message"}} =
             Error.from_map(%{"code" => "worker_timeout"})
  end

  test "rejects invalid error field values" do
    assert {:error, {:invalid_field, "code", " "}} =
             Error.from_map(%{"code" => " ", "message" => "helper timed out"})

    assert {:error, {:invalid_field, "message", 123}} =
             Error.from_map(%{"code" => "worker_timeout", "message" => 123})

    assert {:error, {:invalid_field, "detail", "stderr text"}} =
             Error.from_map(%{
               "code" => "worker_timeout",
               "message" => "helper timed out",
               "detail" => "stderr text"
             })

    assert {:error, {:invalid_field, "error", []}} = Error.from_map([])
  end
end
