defmodule Ourocode.IPC.EnvelopeFieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.IPC.EnvelopeFields

  test "required fetches existing values and reports missing fields" do
    assert EnvelopeFields.required(%{"version" => 1}, "version") == {:ok, 1}

    assert EnvelopeFields.required(%{}, "version") ==
             {:error, {:missing_required_field, "version"}}
  end

  test "required_non_blank_string trims string values" do
    assert EnvelopeFields.required_non_blank_string(%{"message_id" => " msg-1 "}, "message_id") ==
             {:ok, "msg-1"}
  end

  test "required_non_blank_string rejects missing blank and non-string values" do
    assert EnvelopeFields.required_non_blank_string(%{}, "message_id") ==
             {:error, {:missing_required_field, "message_id"}}

    assert EnvelopeFields.required_non_blank_string(%{"message_id" => " "}, "message_id") ==
             {:error, {:invalid_field, "message_id", " "}}

    assert EnvelopeFields.required_non_blank_string(%{"message_id" => 123}, "message_id") ==
             {:error, {:invalid_field, "message_id", 123}}
  end

  test "optional_map defaults missing fields to empty maps" do
    assert EnvelopeFields.optional_map(%{}, "metadata") == {:ok, %{}}

    assert EnvelopeFields.optional_map(%{"metadata" => %{"source" => "helper"}}, "metadata") ==
             {:ok, %{"source" => "helper"}}
  end

  test "optional_map rejects non-map values" do
    assert EnvelopeFields.optional_map(%{"payload" => []}, "payload") ==
             {:error, {:invalid_field, "payload", []}}
  end
end
