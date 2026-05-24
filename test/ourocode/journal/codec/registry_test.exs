defmodule Ourocode.Journal.Codec.RegistryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.Codec.Registry

  test "restores known top-level journal keys" do
    assert Registry.top_level_key("type") == :type
    assert Registry.top_level_key("event_seq") == :event_seq
    assert Registry.top_level_key("external_ids") == :external_ids
    assert Registry.top_level_key("ui_restart_required?") == :ui_restart_required?
  end

  test "leaves unknown top-level keys untouched" do
    assert Registry.top_level_key("plugin-specific-field") == "plugin-specific-field"
  end

  test "restores known persisted atom values" do
    assert Registry.atom_value("parent_call_event") == :parent_call_event
    assert Registry.atom_value("streamable_http") == :streamable_http
    assert Registry.atom_value("release_runtime_resources") == :release_runtime_resources
  end

  test "leaves unknown atom names and non-strings untouched" do
    assert Registry.atom_value("unknown_future_event") == "unknown_future_event"
    assert Registry.atom_value(:already_atom) == :already_atom
  end
end
