defmodule Ourocode.Terminal.RootUITest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.RootUI

  test "initializes the root terminal UI model through the dashboard pane projection" do
    project_dir = File.cwd!()

    assert {:ok, result} =
             RootUI.init(%{
               project_dir: project_dir,
               cwd: project_dir,
               config: Ourocode.Config.defaults()
             })

    assert result.status == :healthy
    assert result.healthy? == true
    assert result.ui_surface == :terminal
    assert result.root_ui_module == RootUI
    assert result.context.ui_surface == :terminal
    assert result.context.root_ui_module == RootUI
    assert result.panes.task_prompt.kind == :natural_language_task_input
    assert result.panes.task_prompt.focused? == true
  end

  test "reports invalid context at the root UI boundary" do
    assert {:error, result} = RootUI.init(%{})

    assert result.status == :unhealthy
    assert result.healthy? == false
    assert result.reason == :invalid_root_ui_context
  end
end
