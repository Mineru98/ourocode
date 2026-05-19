defmodule Ourocode.Plugin.MappingResolverTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.Loader
  alias Ourocode.Plugin.MappingResolver
  alias Ourocode.Plugin.MappingSignatureVerifier
  alias Ourocode.Runtime.Dispatcher
  alias Ourocode.TaskRequest

  defmodule ExistingRuntimeAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:existing_runtime_adapter_called, task_request, context})
      {:ok, {:existing_runtime, task_request.id}}
    end
  end

  defmodule UserRuntimeAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:user_runtime_adapter_called, task_request, context})
      {:ok, {:user_runtime, task_request.id}}
    end
  end

  defmodule OfficialInterviewAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:official_interview_adapter_called, task_request, context})
      {:ok, {:official_interview, task_request.id}}
    end
  end

  defmodule OfficialChildRenderer do
    def render(%{child_id: child_id, pane_state: pane_state}) do
      %{
        id: "official-child-#{child_id}",
        title: "Official child #{child_id}",
        line: "events=#{length(Map.get(pane_state, :stream_entries, []))}"
      }
    end
  end

  defmodule LocalChildRenderer do
    def render(%{child_id: child_id, pane_state: pane_state}) do
      %{
        id: "local-child-#{child_id}",
        title: "Local child #{child_id}",
        line: "local-events=#{length(Map.get(pane_state, :stream_entries, []))}"
      }
    end
  end

  defmodule OfficialSessionOpenAction do
    def execute(payload, context) do
      send(context.test_pid, {:official_session_open_action_called, payload, context})
      {:ok, Map.put(payload.pane_state, :opened_child_id, payload.child_id)}
    end
  end

  defmodule UserSessionOpenAction do
    def execute(payload, context) do
      send(context.test_pid, {:user_session_open_action_called, payload, context})
      {:ok, Map.put(payload.pane_state, :user_opened_child_id, payload.child_id)}
    end
  end

  defmodule LocalSessionOpenAction do
    def execute(payload, context) do
      send(context.test_pid, {:local_session_open_action_called, payload, context})
      {:ok, Map.put(payload.pane_state, :local_opened_child_id, payload.child_id)}
    end
  end

  test "loads trusted official mappings and merges only missing active registry entries" do
    key_id = "official-resolver-key"
    secret = "official-resolver-secret"
    plugin_path = tmp_plugin_dir!("official-resolver")
    manifest_path = Path.join(plugin_path, "capabilities.json")
    plugin_identity = official_plugin_identity()

    adapter_mapping =
      signed_mapping(
        :adapter,
        plugin_identity,
        %{"key" => "ouroboros_workflow.interview", "module" => inspect(OfficialInterviewAdapter)},
        key_id,
        secret
      )

    skipped_adapter_mapping =
      signed_mapping(
        :adapter,
        plugin_identity,
        %{"key" => "runtime", "module" => inspect(OfficialInterviewAdapter)},
        key_id,
        secret
      )

    renderer_mapping =
      signed_mapping(
        :renderer,
        plugin_identity,
        %{"key" => "child_session", "module" => inspect(OfficialChildRenderer)},
        key_id,
        secret
      )

    action_mapping =
      signed_mapping(
        :action,
        plugin_identity,
        %{"key" => "session.open", "module" => inspect(OfficialSessionOpenAction)},
        key_id,
        secret
      )

    File.write!(
      manifest_path,
      Ourocode.Json.encode!(%{
        "capabilities" => ["adapter_mapping", "pane_renderer", "steering_action_mapping"],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"},
        "adapter_mappings" => [adapter_mapping, skipped_adapter_mapping],
        "renderer_mappings" => [renderer_mapping],
        "action_mappings" => [action_mapping]
      })
    )

    {:ok, expected_checksum} = Loader.checksum(plugin_path)

    active_registry = %{
      adapters: %{runtime: ExistingRuntimeAdapter},
      renderers: %{},
      actions: %{}
    }

    assert {:ok,
            %{
              plugin: %{plugin_id: "ouroboros-plugin", trust_classification: "official_trusted"},
              registry: %{
                adapters: adapters,
                renderers: renderers,
                actions: actions
              },
              additions: %{
                adapters: %{{:ouroboros_workflow, :interview} => OfficialInterviewAdapter},
                renderers: %{child_session: OfficialChildRenderer},
                actions: %{{:session, :open} => OfficialSessionOpenAction}
              },
              skipped_existing: %{
                adapters: %{runtime: OfficialInterviewAdapter},
                renderers: %{},
                actions: %{}
              }
            }} =
             MappingResolver.merge_official_mappings(plugin_path, active_registry,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum,
               official_mapping_signing_keys: %{key_id => secret}
             )

    assert adapters.runtime == ExistingRuntimeAdapter
    assert adapters[{:ouroboros_workflow, :interview}] == OfficialInterviewAdapter
    assert renderers.child_session == OfficialChildRenderer
    assert actions[{:session, :open}] == OfficialSessionOpenAction

    {:ok, runtime_request} = TaskRequest.parse("summarize latest journal", id: "runtime-task")

    assert {:ok, {:existing_runtime, "runtime-task"}} =
             Dispatcher.dispatch(runtime_request,
               adapters: adapters,
               context: %{test_pid: self()}
             )

    assert_receive {:existing_runtime_adapter_called, ^runtime_request, %{runtime_source: :auto}}

    {:ok, interview_request} =
      TaskRequest.parse("ooo interview clarify official mapping merge", id: "interview-task")

    assert {:ok, {:official_interview, "interview-task"}} =
             Dispatcher.dispatch(interview_request,
               adapters: adapters,
               context: %{test_pid: self()}
             )

    assert_receive {:official_interview_adapter_called, ^interview_request,
                    %{adapter_route: :interview, runtime_source: :ouroboros}}

    assert %{line: "events=2"} =
             renderers.child_session.render(%{
               child_id: "child-1",
               pane_state: %{stream_entries: [%{event_seq: 1}, %{event_seq: 2}]}
             })

    payload = %{child_id: "child-1", pane_state: %{open_child_ids: []}}

    assert {:ok, %{opened_child_id: "child-1"}} =
             actions[{:session, :open}].execute(payload, %{test_pid: self()})

    assert_receive {:official_session_open_action_called, ^payload, %{test_pid: test_pid}}
    assert test_pid == self()
  end

  test "preserves higher-priority local mappings when official mappings use the same plugin keys" do
    key_id = "official-local-precedence-key"
    secret = "official-local-precedence-secret"
    plugin_path = tmp_plugin_dir!("official-local-precedence")
    manifest_path = Path.join(plugin_path, "capabilities.json")
    plugin_identity = official_plugin_identity()

    adapter_mapping =
      signed_mapping(
        :adapter,
        plugin_identity,
        %{"key" => "runtime", "module" => inspect(OfficialInterviewAdapter)},
        key_id,
        secret
      )

    renderer_mapping =
      signed_mapping(
        :renderer,
        plugin_identity,
        %{"key" => "child_session", "module" => inspect(OfficialChildRenderer)},
        key_id,
        secret
      )

    action_mapping =
      signed_mapping(
        :action,
        plugin_identity,
        %{"key" => "session.open", "module" => inspect(OfficialSessionOpenAction)},
        key_id,
        secret
      )

    File.write!(
      manifest_path,
      Ourocode.Json.encode!(%{
        "capabilities" => ["adapter_mapping", "pane_renderer", "steering_action_mapping"],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"},
        "adapter_mappings" => [adapter_mapping],
        "renderer_mappings" => [renderer_mapping],
        "action_mappings" => [action_mapping]
      })
    )

    {:ok, expected_checksum} = Loader.checksum(plugin_path)

    local_registry = %{
      adapters: %{"runtime" => ExistingRuntimeAdapter},
      renderers: %{"child_session" => LocalChildRenderer},
      actions: %{"session.open" => LocalSessionOpenAction}
    }

    assert {:ok,
            %{
              registry: %{
                adapters: adapters = %{runtime: ExistingRuntimeAdapter},
                renderers: renderers = %{child_session: LocalChildRenderer},
                actions: actions = %{{:session, :open} => LocalSessionOpenAction}
              },
              additions: %{adapters: %{}, renderers: %{}, actions: %{}},
              skipped_existing: %{
                adapters: %{runtime: OfficialInterviewAdapter},
                renderers: %{child_session: OfficialChildRenderer},
                actions: %{{:session, :open} => OfficialSessionOpenAction}
              }
            }} =
             MappingResolver.merge_official_mappings(plugin_path, local_registry,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum,
               official_mapping_signing_keys: %{key_id => secret}
             )

    {:ok, runtime_request} =
      TaskRequest.parse("summarize latest journal", id: "local-runtime-task")

    assert {:ok, {:existing_runtime, "local-runtime-task"}} =
             Dispatcher.dispatch(runtime_request,
               adapters: adapters,
               context: %{test_pid: self()}
             )

    assert_receive {:existing_runtime_adapter_called, ^runtime_request, %{runtime_source: :auto}}

    assert %{id: "local-child-child-2", line: "local-events=1"} =
             renderers.child_session.render(%{
               child_id: "child-2",
               pane_state: %{stream_entries: [%{event_seq: 1}]}
             })

    payload = %{child_id: "child-2", pane_state: %{}}

    assert {:ok, %{local_opened_child_id: "child-2"}} =
             actions[{:session, :open}].execute(payload, %{test_pid: self()})

    assert_receive {:local_session_open_action_called, ^payload, %{test_pid: test_pid}}
    assert test_pid == self()
  end

  test "resolves deterministic active registry with user local official precedence and runnable mappings" do
    key_id = "official-combined-precedence-key"
    secret = "official-combined-precedence-secret"
    plugin_path = tmp_plugin_dir!("official-combined-precedence")
    manifest_path = Path.join(plugin_path, "capabilities.json")
    plugin_identity = official_plugin_identity()

    official_runtime_mapping =
      signed_mapping(
        :adapter,
        plugin_identity,
        %{"key" => "runtime", "module" => inspect(OfficialInterviewAdapter)},
        key_id,
        secret
      )

    official_interview_mapping =
      signed_mapping(
        :adapter,
        plugin_identity,
        %{"key" => "ouroboros_workflow.interview", "module" => inspect(OfficialInterviewAdapter)},
        key_id,
        secret
      )

    official_renderer_mapping =
      signed_mapping(
        :renderer,
        plugin_identity,
        %{"key" => "child_session", "module" => inspect(OfficialChildRenderer)},
        key_id,
        secret
      )

    official_action_mapping =
      signed_mapping(
        :action,
        plugin_identity,
        %{"key" => "session.open", "module" => inspect(OfficialSessionOpenAction)},
        key_id,
        secret
      )

    File.write!(
      manifest_path,
      Ourocode.Json.encode!(%{
        "capabilities" => ["adapter_mapping", "pane_renderer", "steering_action_mapping"],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"},
        "adapter_mappings" => [official_runtime_mapping, official_interview_mapping],
        "renderer_mappings" => [official_renderer_mapping],
        "action_mappings" => [official_action_mapping]
      })
    )

    {:ok, expected_checksum} = Loader.checksum(plugin_path)

    local_registry = %{
      adapters: %{"runtime" => ExistingRuntimeAdapter},
      renderers: %{"child_session" => LocalChildRenderer},
      actions: %{"session.open" => LocalSessionOpenAction}
    }

    user_registry = %{
      adapters: %{"runtime" => UserRuntimeAdapter},
      renderers: %{},
      actions: %{"session.open" => UserSessionOpenAction}
    }

    assert {:ok,
            %{
              registry: %{
                adapters: adapters,
                renderers: renderers,
                actions: actions
              },
              sources: %{
                adapters: %{
                  :runtime => :user,
                  {:ouroboros_workflow, :interview} => :official
                },
                renderers: %{child_session: :local},
                actions: %{{:session, :open} => :user}
              },
              overridden: %{
                official: %{
                  adapters: %{runtime: OfficialInterviewAdapter},
                  renderers: %{child_session: OfficialChildRenderer},
                  actions: %{{:session, :open} => OfficialSessionOpenAction}
                },
                local: %{
                  adapters: %{runtime: ExistingRuntimeAdapter},
                  renderers: %{},
                  actions: %{{:session, :open} => LocalSessionOpenAction}
                },
                user: %{adapters: %{}, renderers: %{}, actions: %{}}
              }
            }} =
             MappingResolver.resolve_active_registry(plugin_path, user_registry, local_registry,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum,
               official_mapping_signing_keys: %{key_id => secret}
             )

    assert adapters.runtime == UserRuntimeAdapter
    assert adapters[{:ouroboros_workflow, :interview}] == OfficialInterviewAdapter
    assert renderers.child_session == LocalChildRenderer
    assert actions[{:session, :open}] == UserSessionOpenAction

    assert {:ok,
            %{
              registry: %{
                adapters: ^adapters,
                renderers: ^renderers,
                actions: ^actions
              }
            }} =
             MappingResolver.resolve_active_registry(plugin_path, user_registry, local_registry,
               allowed_roots: [plugin_path],
               expected_checksum: expected_checksum,
               official_mapping_signing_keys: %{key_id => secret}
             )

    {:ok, runtime_request} =
      TaskRequest.parse("summarize latest journal", id: "user-runtime-task")

    assert {:ok, {:user_runtime, "user-runtime-task"}} =
             Dispatcher.dispatch(runtime_request,
               adapters: adapters,
               context: %{test_pid: self()}
             )

    assert_receive {:user_runtime_adapter_called, ^runtime_request, %{runtime_source: :auto}}

    {:ok, interview_request} =
      TaskRequest.parse("ooo interview clarify precedence", id: "official-interview-task")

    assert {:ok, {:official_interview, "official-interview-task"}} =
             Dispatcher.dispatch(interview_request,
               adapters: adapters,
               context: %{test_pid: self()}
             )

    assert_receive {:official_interview_adapter_called, ^interview_request,
                    %{adapter_route: :interview, runtime_source: :ouroboros}}

    assert %{id: "local-child-child-3", line: "local-events=1"} =
             renderers.child_session.render(%{
               child_id: "child-3",
               pane_state: %{stream_entries: [%{event_seq: 1}]}
             })

    payload = %{child_id: "child-3", pane_state: %{}}

    assert {:ok, %{user_opened_child_id: "child-3"}} =
             actions[{:session, :open}].execute(payload, %{test_pid: self()})

    assert_receive {:user_session_open_action_called, ^payload, %{test_pid: test_pid}}
    assert test_pid == self()
  end

  defp tmp_plugin_dir!(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-mapping-resolver-test-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)

    on_exit(fn ->
      File.rm_rf!(path)
    end)

    path
  end

  defp official_plugin_identity do
    %{
      plugin_id: "ouroboros-plugin",
      trust_classification: "official_trusted"
    }
  end

  defp signed_mapping(mapping_type, plugin, mapping, key_id, secret) do
    signature = MappingSignatureVerifier.sign(mapping_type, plugin, mapping, secret)

    Map.put(mapping, "signature", %{
      "algorithm" => "hmac-sha256",
      "key_id" => key_id,
      "value" => signature
    })
  end
end
