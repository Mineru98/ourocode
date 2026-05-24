defmodule Ourocode.Command.Registry.BuiltinTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry.Builtin

  test "normalizes builtin commands into registry entries" do
    entries = Builtin.entries()

    assert Enum.map(entries, & &1.slash) == [
             "/help",
             "/commands",
             "/skills",
             "/capabilities",
             "/preflight",
             "/clear",
             "/resume",
             "/exit",
             "/quit",
             "/status",
             "/pane",
             "/children",
             "/queue",
             "/hooks",
             "/wonder",
             "/plugins",
             "/mcp",
             "/sessions",
             "/config",
             "/model",
             "/login",
             "/logout",
             "/reload",
             "/replay"
           ]

    assert Enum.all?(entries, &(&1.source == :builtin))

    assert Enum.map(Enum.filter(entries, &(&1.availability == :stub)), & &1.slash) == [
             "/mcp",
             "/sessions",
             "/config"
           ]

    assert Enum.all?(entries, fn entry ->
             entry.source == :builtin and
               entry.source_id == "builtin" and
               entry.type == :slash_command and
               entry.runnable? == true and
               String.starts_with?(entry.id, "builtin:/") and
               String.starts_with?(entry.slash, "/") and
               is_binary(entry.summary) and
               entry.run_spec.kind == :builtin_action
           end)

    assert Map.new(entries, &{&1.slash, {&1.availability, &1.run_spec.action}})
           |> Map.take([
             "/clear",
             "/resume",
             "/exit",
             "/quit",
             "/status",
             "/preflight",
             "/plugins",
             "/mcp",
             "/sessions",
             "/config"
           ]) == %{
             "/clear" => {:available, :clear_screen},
             "/resume" => {:available, :resume_session},
             "/exit" => {:available, :exit},
             "/quit" => {:available, :exit},
             "/status" => {:available, :show_status},
             "/preflight" => {:available, :show_preflight},
             "/plugins" => {:available, :show_plugins},
             "/mcp" => {:stub, :show_mcp},
             "/sessions" => {:stub, :show_sessions},
             "/config" => {:stub, :show_config}
           }

    pane = Enum.find(entries, &(&1.slash == "/pane"))

    assert pane.category == :steering

    assert pane.args == [
             %{name: "pane_id", required?: true, description: "Pane id or child session id"}
           ]
  end

  test "normalizes contextual action definitions with builtin metadata" do
    interrupt = Builtin.normalize!(Builtin.interrupt_definition())
    cancel = Builtin.normalize!(Builtin.cancel_definition())

    assert interrupt.slash == "/interrupt"
    assert interrupt.aliases == ["/stop-child"]
    assert interrupt.run_spec.action == :interrupt_focused_child
    assert interrupt.metadata.introduced_in == :interactive_baseline

    assert cancel.slash == "/cancel"
    assert cancel.aliases == ["/cancel-child"]

    assert cancel.args == [
             %{
               name: "reason",
               required?: false,
               description: "Optional cancellation reason sent to the child session"
             }
           ]
  end
end
