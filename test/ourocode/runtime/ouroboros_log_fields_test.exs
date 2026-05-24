defmodule Ourocode.Runtime.OuroborosLogFieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.OuroborosLogFields

  test "parses bare, single-quoted, and double-quoted fields" do
    assert OuroborosLogFields.parse(
             ~s(session_id=interview_1 error='network failed' label="hello world" count=3)
           ) == %{
             "session_id" => "interview_1",
             "error" => "network failed",
             "label" => "hello world",
             "count" => "3"
           }
  end

  test "ignores malformed fragments" do
    assert OuroborosLogFields.parse("ok=yes 9bad=no no-value") == %{"ok" => "yes"}
  end

  test "handles non-binary input as empty fields" do
    assert OuroborosLogFields.parse(nil) == %{}
  end
end
