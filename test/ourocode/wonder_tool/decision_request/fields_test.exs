defmodule Ourocode.WonderTool.DecisionRequest.FieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.WonderTool.DecisionRequest.Fields

  test "first returns the first present atom or string key value" do
    assert Fields.first(%{"name" => "tool", name: "atom"}, [:missing, "name", :name]) == "tool"
    assert Fields.first(%{}, ["missing"]) == nil
  end

  test "first_present preserves the matched key" do
    assert Fields.first_present(%{choices: ["a"]}, ["options", :choices]) == {:choices, ["a"]}
  end

  test "map_field and string_field filter and normalize values" do
    assert Fields.map_field(%{"externalIds" => %{session_id: "s1"}}, ["externalIds"]) == %{
             session_id: "s1"
           }

    assert Fields.map_field(%{"externalIds" => "bad"}, ["externalIds"]) == nil
    assert Fields.string_field(%{"requestId" => " req-1 "}, ["requestId"]) == "req-1"
    assert Fields.string_field(%{"requestId" => " "}, ["requestId"]) == nil
  end

  test "put_present ignores nil values" do
    assert Fields.put_present(%{a: 1}, :b, nil) == %{a: 1}
    assert Fields.put_present(%{a: 1}, :b, 2) == %{a: 1, b: 2}
  end
end
