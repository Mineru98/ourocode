defmodule Ourocode.Terminal.PluginStatusFieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.PluginStatusFields

  test "looks up atom and string keys with defaults" do
    assert PluginStatusFields.value(%{id: "alpha"}, :id) == "alpha"
    assert PluginStatusFields.value(%{"id" => "beta"}, :id) == "beta"
    assert PluginStatusFields.value(%{}, :id, "plugin") == "plugin"
  end

  test "coerces text values for renderable fields" do
    assert PluginStatusFields.text(%{source: :official}, :source) == "official"
    assert PluginStatusFields.text(%{version: 3}, :version) == "3"
    assert PluginStatusFields.text(%{metadata: %{}}, :metadata) == nil
  end

  test "coerces booleans only when values are boolean" do
    assert PluginStatusFields.boolean(%{enabled?: true}, :enabled?, false) == true
    assert PluginStatusFields.boolean(%{"enabled?" => false}, :enabled?, true) == false
    assert PluginStatusFields.boolean(%{enabled?: "true"}, :enabled?, false) == false
  end
end
