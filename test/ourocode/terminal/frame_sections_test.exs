defmodule Ourocode.Terminal.FrameSectionsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.FrameSections

  test "parses titled frame sections and skips region marker rows" do
    frame = """
    +-- ourocode terminal region=header x=0
    | [header-region] x=0 y=0
    | runtime=ready status=healthy transports=stdio,sse
    +--
    +-- Parent/Child Sessions x=0
    | parent active
    | child session-one
    | child empty
    +--
    """

    assert FrameSections.parse(frame) == [
             {"ourocode terminal", ["runtime=ready status=healthy transports=stdio,sse"]},
             {"Parent/Child Sessions", ["parent active", "child session-one", "child empty"]}
           ]
  end

  test "extracts status fields and counts non-empty session and plugin rows" do
    sections = [
      {"ourocode terminal", ["runtime=ready status=healthy"]},
      {"State", ["queued=2 hooks=running"]},
      {"Parent/Child Sessions", ["parent active", "child alpha", "child empty"]},
      {"Plugin Status", ["status=ready", "plugin one", "plugin two", "empty"]}
    ]

    assert FrameSections.status_fields(sections) == %{
             "runtime" => "ready",
             "status" => "healthy",
             "queued" => "2",
             "hooks" => "running"
           }

    assert FrameSections.session_count(sections) == 2
    assert FrameSections.plugin_count(sections) == 2

    assert FrameSections.body(sections, "Plugin") == [
             "status=ready",
             "plugin one",
             "plugin two",
             "empty"
           ]
  end
end
