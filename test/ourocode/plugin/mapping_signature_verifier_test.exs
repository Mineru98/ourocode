defmodule Ourocode.Plugin.MappingSignatureVerifierTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ActionMappingLoader
  alias Ourocode.Plugin.AdapterMappingLoader
  alias Ourocode.Plugin.LoadError
  alias Ourocode.Plugin.Loader
  alias Ourocode.Plugin.MappingSignatureVerifier
  alias Ourocode.Plugin.RendererMappingLoader
  alias Ourocode.Runtime.Dispatcher
  alias Ourocode.TaskRequest

  defmodule SignedAdapter do
    @behaviour Ourocode.Runtime.Adapter

    @impl true
    def execute(task_request, context) do
      send(context.test_pid, {:signed_adapter_called, task_request, context})
      {:ok, {:signed_adapter, task_request.id}}
    end
  end

  defmodule SignedRenderer do
    def render(%{child_id: child_id, pane_state: pane_state}) do
      %{
        id: "signed-renderer-#{child_id}",
        title: "Signed child #{child_id}",
        line: "entries=#{length(Map.get(pane_state, :stream_entries, []))}"
      }
    end
  end

  defmodule SignedAction do
    def execute(payload, context) do
      send(context.test_pid, {:signed_action_called, payload, context})
      {:ok, Map.put(payload, :signed_action?, true)}
    end
  end

  test "accepts signed official ouroboros-plugin adapter renderer and action mappings" do
    key_id = "official-test-key"
    secret = "official-test-secret"
    plugin_path = tmp_plugin_dir!("signed-official-mappings")

    plugin_identity = %{
      plugin_id: "ouroboros-plugin",
      trust_classification: "official_trusted"
    }

    adapter_mapping =
      signed_mapping(
        :adapter,
        plugin_identity,
        %{"key" => "ouroboros_workflow.interview", "module" => inspect(SignedAdapter)},
        key_id,
        secret
      )

    renderer_mapping =
      signed_mapping(
        :renderer,
        plugin_identity,
        %{"key" => "child_session", "module" => inspect(SignedRenderer)},
        key_id,
        secret
      )

    action_mapping =
      signed_mapping(
        :action,
        plugin_identity,
        %{"key" => "session.focus", "module" => inspect(SignedAction)},
        key_id,
        secret
      )

    File.write!(
      Path.join(plugin_path, "capabilities.json"),
      Ourocode.Json.encode!(%{
        "capabilities" => ["adapter_mapping", "pane_renderer", "steering_action_mapping"],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"},
        "adapter_mappings" => [adapter_mapping],
        "renderer_mappings" => [renderer_mapping],
        "action_mappings" => [action_mapping]
      })
    )

    {:ok, expected_checksum} = Loader.checksum(plugin_path)

    loader_opts = [
      allowed_roots: [plugin_path],
      expected_checksum: expected_checksum,
      official_mapping_signing_keys: %{key_id => secret}
    ]

    assert {:ok,
            %{
              adapter_mappings: [
                %{
                  "signature" => %{
                    "algorithm" => "hmac-sha256",
                    "key_id" => ^key_id,
                    "value" => adapter_signature
                  }
                }
              ],
              adapters: adapters = %{{:ouroboros_workflow, :interview} => SignedAdapter}
            }} = AdapterMappingLoader.load_default(plugin_path, loader_opts)

    assert is_binary(adapter_signature)

    assert {:ok,
            %{
              renderer_mappings: [
                %{
                  "signature" => %{
                    "algorithm" => "hmac-sha256",
                    "key_id" => ^key_id,
                    "value" => renderer_signature
                  }
                }
              ],
              renderers: renderers = %{child_session: SignedRenderer}
            }} = RendererMappingLoader.load_default(plugin_path, loader_opts)

    assert is_binary(renderer_signature)

    assert {:ok,
            %{
              action_mappings: [
                %{
                  "signature" => %{
                    "algorithm" => "hmac-sha256",
                    "key_id" => ^key_id,
                    "value" => action_signature
                  }
                }
              ],
              actions: actions = %{{:session, :focus} => SignedAction}
            }} = ActionMappingLoader.load_default(plugin_path, loader_opts)

    assert is_binary(action_signature)

    {:ok, task_request} = TaskRequest.parse("ooo interview signed mapping", id: "signed-task")

    assert {:ok, {:signed_adapter, "signed-task"}} =
             Dispatcher.dispatch(task_request,
               adapters: adapters,
               context: %{test_pid: self()}
             )

    assert_receive {:signed_adapter_called, ^task_request, adapter_context}
    assert adapter_context.runtime_source == :ouroboros

    assert %{
             id: "signed-renderer-child-1",
             title: "Signed child child-1",
             line: "entries=1"
           } =
             renderers.child_session.render(%{
               child_id: "child-1",
               pane_state: %{stream_entries: [%{event_seq: 1, text: "hello"}]}
             })

    payload = %{child_id: "child-1", pane_state: %{focused_child_id: nil}}

    assert {:ok, %{signed_action?: true, child_id: "child-1"}} =
             actions[{:session, :focus}].execute(payload, %{test_pid: self()})

    assert_receive {:signed_action_called, ^payload, %{test_pid: test_pid}}
    assert test_pid == self()
  end

  test "rejects official ouroboros-plugin mappings with invalid signatures" do
    key_id = "official-test-key"
    secret = "official-test-secret"

    cases = [
      {:adapter, AdapterMappingLoader, "adapter_mappings", "adapter_mapping",
       %{"key" => "runtime", "module" => inspect(SignedAdapter)}},
      {:renderer, RendererMappingLoader, "renderer_mappings", "pane_renderer",
       %{"key" => "child_session", "module" => inspect(SignedRenderer)}},
      {:action, ActionMappingLoader, "action_mappings", "steering_action_mapping",
       %{"key" => "session.focus", "module" => inspect(SignedAction)}}
    ]

    for {_mapping_type, loader, manifest_key, capability, mapping} <- cases do
      plugin_path = tmp_plugin_dir!("invalid-signed-#{manifest_key}")

      invalid_mapping =
        Map.put(mapping, "signature", %{
          "algorithm" => "hmac-sha256",
          "key_id" => key_id,
          "value" => "not-a-valid-signature-for-this-payload"
        })

      write_plugin_manifest!(plugin_path, capability, manifest_key, [invalid_mapping])

      {:ok, expected_checksum} = Loader.checksum(plugin_path)

      assert {:error,
              %LoadError{
                reason: :invalid_mapping_signature,
                plugin_path: expanded_path
              }} =
               loader.load_default(plugin_path,
                 allowed_roots: [plugin_path],
                 expected_checksum: expected_checksum,
                 official_mapping_signing_keys: %{key_id => secret}
               )

      assert expanded_path == Path.expand(plugin_path)
    end
  end

  test "rejects official ouroboros-plugin mappings when signature is missing" do
    cases = [
      {AdapterMappingLoader, "adapter_mappings", "adapter_mapping",
       %{"key" => "runtime", "module" => inspect(SignedAdapter)}},
      {RendererMappingLoader, "renderer_mappings", "pane_renderer",
       %{"key" => "child_session", "module" => inspect(SignedRenderer)}},
      {ActionMappingLoader, "action_mappings", "steering_action_mapping",
       %{"key" => "session.focus", "module" => inspect(SignedAction)}}
    ]

    for {loader, manifest_key, capability, unsigned_mapping} <- cases do
      plugin_path = tmp_plugin_dir!("missing-signature-#{manifest_key}")

      write_plugin_manifest!(plugin_path, capability, manifest_key, [unsigned_mapping])

      {:ok, expected_checksum} = Loader.checksum(plugin_path)

      assert {:error,
              %LoadError{
                reason: :missing_mapping_signature,
                plugin_path: expanded_path
              }} =
               loader.load_default(plugin_path,
                 allowed_roots: [plugin_path],
                 expected_checksum: expected_checksum
               )

      assert expanded_path == Path.expand(plugin_path)
    end
  end

  test "rejects official ouroboros-plugin mappings when signature payload does not match mapping" do
    key_id = "official-test-key"
    secret = "official-test-secret"

    plugin_identity = %{
      plugin_id: "ouroboros-plugin",
      trust_classification: "official_trusted"
    }

    cases = [
      {:adapter, AdapterMappingLoader, "adapter_mappings", "adapter_mapping",
       %{"key" => "runtime", "module" => inspect(SignedAdapter)},
       %{"key" => "mcp_stdio", "module" => inspect(SignedAdapter)}},
      {:renderer, RendererMappingLoader, "renderer_mappings", "pane_renderer",
       %{"key" => "child_session", "module" => inspect(SignedRenderer)},
       %{"key" => "task_prompt", "module" => inspect(SignedRenderer)}},
      {:action, ActionMappingLoader, "action_mappings", "steering_action_mapping",
       %{"key" => "session.focus", "module" => inspect(SignedAction)},
       %{"key" => "pane.open", "module" => inspect(SignedAction)}}
    ]

    for {mapping_type, loader, manifest_key, capability, signed_payload, tampered_mapping} <-
          cases do
      plugin_path = tmp_plugin_dir!("payload-mismatch-#{manifest_key}")

      signature =
        MappingSignatureVerifier.sign(mapping_type, plugin_identity, signed_payload, secret)

      mismatched_mapping =
        Map.put(tampered_mapping, "signature", %{
          "algorithm" => "hmac-sha256",
          "key_id" => key_id,
          "value" => signature
        })

      write_plugin_manifest!(plugin_path, capability, manifest_key, [mismatched_mapping])

      {:ok, expected_checksum} = Loader.checksum(plugin_path)

      assert {:error,
              %LoadError{
                reason: :invalid_mapping_signature,
                plugin_path: expanded_path
              }} =
               loader.load_default(plugin_path,
                 allowed_roots: [plugin_path],
                 expected_checksum: expected_checksum,
                 official_mapping_signing_keys: %{key_id => secret}
               )

      assert expanded_path == Path.expand(plugin_path)
    end
  end

  defp signed_mapping(mapping_type, plugin, mapping, key_id, secret) do
    signature = MappingSignatureVerifier.sign(mapping_type, plugin, mapping, secret)

    Map.put(mapping, "signature", %{
      "algorithm" => "hmac-sha256",
      "key_id" => key_id,
      "value" => signature
    })
  end

  defp write_plugin_manifest!(plugin_path, capability, manifest_key, mappings) do
    File.write!(
      Path.join(plugin_path, "capabilities.json"),
      Ourocode.Json.encode!(%{
        "capabilities" => [capability],
        "plugin" => %{"id" => "ouroboros-plugin", "trust_tier" => "official"},
        manifest_key => mappings
      })
    )
  end

  defp tmp_plugin_dir!(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-mapping-signature-verifier-test-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)

    on_exit(fn ->
      File.rm_rf!(path)
    end)

    path
  end
end
