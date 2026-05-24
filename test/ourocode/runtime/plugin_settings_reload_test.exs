defmodule Ourocode.Runtime.PluginSettingsReloadTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.PluginSettingsReload

  test "session_settings_patch prefers explicit session_settings over legacy session key" do
    settings = %{
      "session" => %{"stream_mailbox_capacity" => 4},
      "session_settings" => %{"stream_mailbox_capacity" => 12}
    }

    assert PluginSettingsReload.session_settings_patch(settings) == %{
             "stream_mailbox_capacity" => 12
           }
  end

  test "pane_settings_patch falls back to legacy pane key" do
    settings = %{"pane" => %{"status_label" => "Insert"}}

    assert PluginSettingsReload.pane_settings_patch(settings) == %{"status_label" => "Insert"}
  end

  test "apply reports unavailable runtime shape" do
    assert PluginSettingsReload.apply(%{}, %{}, []) ==
             {:error, :plugin_settings_reload_unavailable}
  end
end
