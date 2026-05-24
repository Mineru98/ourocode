defmodule Ourocode.IPC.RequestFieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.IPC.RequestFields

  test "normalizes non-blank request strings" do
    assert RequestFields.non_blank_string(" helper.scan ", "method") == {:ok, "helper.scan"}

    assert RequestFields.non_blank_string(" ", "method") ==
             {:error, {:invalid_field, "method", " "}}

    assert RequestFields.non_blank_string(nil, "method") ==
             {:error, {:invalid_field, "method", nil}}
  end

  test "requires payload strings by field name" do
    assert RequestFields.required_non_blank_string(%{"action" => " run "}, "action") ==
             {:ok, "run"}

    assert RequestFields.required_non_blank_string(%{}, "action") ==
             {:error, {:missing_required_field, "action"}}
  end

  test "validates optional and direct map fields" do
    assert RequestFields.optional_map(%{}, "params") == {:ok, %{}}

    assert RequestFields.optional_map(%{"params" => %{"path" => "lib"}}, "params") ==
             {:ok, %{"path" => "lib"}}

    assert RequestFields.optional_map(%{"params" => []}, "params") ==
             {:error, {:invalid_field, "params", []}}

    assert RequestFields.map_field(%{"rust_worker" => "scan"}, "metadata") ==
             {:ok, %{"rust_worker" => "scan"}}

    assert RequestFields.map_field([], "metadata") == {:error, {:invalid_field, "metadata", []}}
  end
end
