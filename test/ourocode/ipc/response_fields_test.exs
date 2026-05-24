defmodule Ourocode.IPC.ResponseFieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.IPC.Error
  alias Ourocode.IPC.ResponseFields

  test "normalizes non-blank strings and statuses" do
    assert ResponseFields.non_blank_string(" req-1 ", "request_id") == {:ok, "req-1"}

    assert ResponseFields.non_blank_string(" ", "request_id") ==
             {:error, {:invalid_field, "request_id", " "}}

    assert ResponseFields.non_blank_string(:bad, "request_id") ==
             {:error, {:invalid_field, "request_id", :bad}}

    assert ResponseFields.required_non_blank_string(%{"request_id" => " req-1 "}, "request_id") ==
             {:ok, "req-1"}

    assert ResponseFields.required_non_blank_string(%{}, "request_id") ==
             {:error, {:missing_required_field, "request_id"}}

    assert ResponseFields.normalize_status(:ok) == {:ok, "ok"}
    assert ResponseFields.normalize_status(:error) == {:ok, "error"}

    assert ResponseFields.normalize_status("pending") ==
             {:error, {:invalid_field, "status", "pending"}}
  end

  test "validates result fields according to response status" do
    assert ResponseFields.result_for_status(%{"result" => %{"count" => 1}}, "ok") ==
             {:ok, %{"count" => 1}}

    assert ResponseFields.result_for_status(%{}, "ok") ==
             {:error, {:missing_required_field, "result"}}

    assert ResponseFields.result_for_status(%{"result" => []}, "ok") ==
             {:error, {:invalid_field, "result", []}}

    assert ResponseFields.result_for_status(%{}, "error") == {:ok, %{}}

    assert ResponseFields.result_for_status(%{"result" => %{"partial" => true}}, "error") ==
             {:ok, %{"partial" => true}}
  end

  test "validates status-specific error payloads" do
    assert ResponseFields.error_for_status("ok", nil) == {:ok, nil}

    assert ResponseFields.error_for_status("ok", %{"code" => "unexpected"}) ==
             {:error, {:invalid_field, "error", %{"code" => "unexpected"}}}

    assert ResponseFields.error_for_status("error", nil) ==
             {:error, {:missing_required_field, "error"}}

    assert ResponseFields.error_for_status("error", %{"code" => "timeout"}) ==
             {:error, {:missing_required_field, "message"}}

    {:ok, error} = Error.new("worker_exit", "helper exited", %{"status" => 2})

    assert ResponseFields.error_for_status("error", error) ==
             {:ok,
              %{
                "code" => "worker_exit",
                "message" => "helper exited",
                "detail" => %{"status" => 2}
              }}
  end

  test "validates optional map fields" do
    assert ResponseFields.map_field(%{"worker" => "ok"}, "metadata") == {:ok, %{"worker" => "ok"}}
    assert ResponseFields.map_field([], "metadata") == {:error, {:invalid_field, "metadata", []}}
  end
end
