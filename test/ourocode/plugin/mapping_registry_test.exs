defmodule Ourocode.Plugin.MappingRegistryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.MappingRegistry

  defmodule OfficialRuntime, do: def(run, do: :official_runtime)
  defmodule OfficialInterview, do: def(run, do: :official_interview)
  defmodule OfficialRenderer, do: def(render(_), do: :official_renderer)
  defmodule OfficialAction, do: def(execute(_, _), do: :official_action)
  defmodule LocalRuntime, do: def(run, do: :local_runtime)
  defmodule LocalRenderer, do: def(render(_), do: :local_renderer)
  defmodule LocalAction, do: def(execute(_, _), do: :local_action)
  defmodule UserRuntime, do: def(run, do: :user_runtime)
  defmodule UserAction, do: def(execute(_, _), do: :user_action)

  test "normalizes legacy string aliases across registry sections" do
    assert %{
             adapters: %{
               :runtime => OfficialRuntime,
               {:ouroboros_workflow, :interview} => OfficialInterview,
               {:mcp, :sse} => OfficialRuntime,
               "custom.adapter" => OfficialRuntime
             },
             renderers: %{
               parent_mcp: OfficialRenderer,
               wonder_tool: OfficialRenderer
             },
             actions: %{
               {:session, :open} => OfficialAction,
               {:wonder_tool, :decide} => OfficialAction,
               session_focus: OfficialAction
             }
           } =
             MappingRegistry.normalize(%{
               "adapters" => %{
                 "runtime" => OfficialRuntime,
                 "ouroboros_workflow.interview" => OfficialInterview,
                 "mcp.sse" => OfficialRuntime,
                 "custom.adapter" => OfficialRuntime
               },
               "renderers" => %{
                 "parent_mcp_call" => OfficialRenderer,
                 "wonderTool" => OfficialRenderer
               },
               "actions" => %{
                 "session.open" => OfficialAction,
                 "wonderTool.decide" => OfficialAction,
                 "session_focus" => OfficialAction
               }
             })
  end

  test "overlays registries and records winning sources plus overridden entries" do
    official = %{
      adapters: %{
        :runtime => OfficialRuntime,
        {:ouroboros_workflow, :interview} => OfficialInterview
      },
      renderers: %{child_session: OfficialRenderer},
      actions: %{{:session, :open} => OfficialAction}
    }

    local = %{
      adapters: %{runtime: LocalRuntime},
      renderers: %{child_session: LocalRenderer},
      actions: %{{:session, :open} => LocalAction}
    }

    user = %{
      adapters: %{runtime: UserRuntime},
      renderers: %{},
      actions: %{{:session, :open} => UserAction}
    }

    assert MappingRegistry.overlay([official, local, user]) == %{
             adapters: %{
               :runtime => UserRuntime,
               {:ouroboros_workflow, :interview} => OfficialInterview
             },
             renderers: %{child_session: LocalRenderer},
             actions: %{{:session, :open} => UserAction}
           }

    assert MappingRegistry.sources(official, local, user) == %{
             adapters: %{
               :runtime => :user,
               {:ouroboros_workflow, :interview} => :official
             },
             renderers: %{child_session: :local},
             actions: %{{:session, :open} => :user}
           }

    assert MappingRegistry.overridden(official, local, user) == %{
             official: %{
               adapters: %{runtime: OfficialRuntime},
               renderers: %{child_session: OfficialRenderer},
               actions: %{{:session, :open} => OfficialAction}
             },
             local: %{
               adapters: %{runtime: LocalRuntime},
               renderers: %{},
               actions: %{{:session, :open} => LocalAction}
             },
             user: MappingRegistry.empty()
           }
  end

  test "splits missing additions from existing active entries" do
    active = %{runtime: LocalRuntime}

    loaded = %{
      :runtime => OfficialRuntime,
      {:ouroboros_workflow, :interview} => OfficialInterview
    }

    assert MappingRegistry.missing_entries(active, loaded) == %{
             {:ouroboros_workflow, :interview} => OfficialInterview
           }

    assert MappingRegistry.existing_entries(active, loaded) == %{runtime: OfficialRuntime}
  end
end
