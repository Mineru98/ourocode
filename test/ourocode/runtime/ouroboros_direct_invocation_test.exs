defmodule Ourocode.Runtime.OuroborosDirectInvocationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.OuroborosDirectInvocation
  alias Ourocode.TaskRequest

  test "builds cancel, resume, and setup CLI actions" do
    cancel = parse!("ooo cancel execution exec-1 reason stale job")

    assert {:ok, action} =
             OuroborosDirectInvocation.build_action(cancel, %{}, :cancel)

    assert action == %{
             mode: :command,
             command: "ouroboros",
             args: ["cancel", "execution", "exec-1", "--reason", "stale job"]
           }

    resume = parse!("ooo resume-session --all")

    assert {:ok, action} =
             OuroborosDirectInvocation.build_action(resume, %{}, :resume_session)

    assert action.args == ["resume", "--all"]

    setup = parse!("ooo setup")

    assert {:ok, action} =
             OuroborosDirectInvocation.build_action(setup, %{}, :setup)

    assert action.args == ["setup", "--runtime", "codex"]
  end

  test "builds guided surfaces for update, publish, welcome, tutorial, and help" do
    assert {:ok, %{mode: :guided_steps, steps: update_steps}} =
             "ooo update --pre"
             |> parse!()
             |> OuroborosDirectInvocation.build_action(%{}, :update)

    assert Enum.any?(update_steps, &(&1.id == "current_version"))
    assert Enum.any?(update_steps, &(&1.id == "upgrade"))

    assert {:ok, %{mode: :guided_steps, steps: publish_steps}} =
             "ooo publish seed_abc.yaml"
             |> parse!()
             |> OuroborosDirectInvocation.build_action(%{}, :publish)

    assert Enum.any?(publish_steps, &(&1.id == "check_gh"))
    assert Enum.any?(publish_steps, &(&1[:seed_path] == "seed_abc.yaml"))

    for {input, route, step_id} <- [
          {"ooo welcome --skip", :welcome, "welcome"},
          {"ooo tutorial", :tutorial, "tutorial"},
          {"ooo help", :help, "help"}
        ] do
      assert {:ok, %{mode: :guided_steps, steps: [%{id: ^step_id}]}} =
               input
               |> parse!()
               |> OuroborosDirectInvocation.build_action(%{}, route)
    end
  end

  test "runs command actions through the guarded external command runner when configured" do
    task = parse!("ooo resume-session", id: "resume-task")

    runner = fn command, args, opts ->
      send(self(), {:ran, command, args, opts})
      {:ok, %{exit_status: 0, stdout: "ok"}}
    end

    assert {:ok,
            %{
              status: :invoked,
              mode: :command,
              result: %{exit_status: 0, stdout: "ok"}
            }} =
             OuroborosDirectInvocation.execute(task, %{
               external_command_runner: runner,
               cwd: "/tmp/project"
             })

    assert_receive {:ran, "ouroboros", ["resume"], [cd: "/tmp/project"]}
  end

  defp parse!(input, opts \\ []) do
    {:ok, task} = TaskRequest.parse(input, opts)
    task
  end
end
