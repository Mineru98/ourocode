defmodule Ourocode.Acp.ServerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Acp.Server
  alias Ourocode.Json
  alias Ourocode.Model
  alias Ourocode.Model.Conversation

  @initialize ~s({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}})
  @new_session ~s({"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp/proj","mcpServers":[]}})
  @prompt ~s({"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"sess_test","prompt":[{"type":"text","text":"ping"}]}})
  @cancel ~s({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"sess_test"}})

  test "handshake, streamed prompt turn, and end_turn stop reason" do
    parent = self()

    model =
      model(fn prompt, opts, on_chunk ->
        send(parent, {:ran, prompt, Keyword.get(opts, :history)})
        on_chunk.("po")
        on_chunk.("ng")
        {:ok, "pong"}
      end)

    frames = run_server([@initialize, @new_session, @prompt], model)

    assert [init, new_session, chunk1, chunk2, done] = frames

    assert init["id"] == 0
    assert init["result"]["protocolVersion"] == 1
    assert init["result"]["agentInfo"]["name"] == "ourocode"

    assert new_session["id"] == 1
    assert new_session["result"]["sessionId"] == "sess_test"

    assert chunk1["method"] == "session/update"
    assert chunk1["params"]["update"]["content"]["text"] == "po"
    assert chunk2["params"]["update"]["content"]["text"] == "ng"

    assert done["id"] == 2
    assert done["result"]["stopReason"] == "end_turn"

    assert_received {:ran, "ping", %Conversation{turns: []}}
  end

  test "session/cancel answers the pending prompt with the cancelled stop reason" do
    model = model(fn _prompt, _opts, _on_chunk -> Process.sleep(:infinity) end)

    frames = run_server([@initialize, @new_session, @prompt, @cancel], model)

    cancelled = List.last(frames)
    assert cancelled["id"] == 2
    assert cancelled["result"]["stopReason"] == "cancelled"
  end

  test "protocol errors: unknown session, unknown method, invalid frame" do
    model = model(fn _prompt, _opts, _on_chunk -> {:ok, "unused"} end)

    bad_prompt =
      ~s({"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"nope","prompt":[{"type":"text","text":"x"}]}})

    unknown = ~s({"jsonrpc":"2.0","id":8,"method":"session/fork","params":{}})

    assert [bad, unsupported, invalid] =
             run_server([bad_prompt, unknown, "garbage"], model)

    assert bad["id"] == 7
    assert bad["error"]["code"] == -32602

    assert unsupported["id"] == 8
    assert unsupported["error"]["code"] == -32601

    assert invalid["error"]["code"] == -32700
  end

  test "a model failure surfaces as a JSON-RPC error for the prompt" do
    model = model(fn _prompt, _opts, _on_chunk -> {:error, :timeout} end)

    frames = run_server([@initialize, @new_session, @prompt], model)
    failed = List.last(frames)

    assert failed["id"] == 2
    assert failed["error"]["code"] == -32603
    assert failed["error"]["message"] =~ "timeout"
  end

  test "model_id_from_env maps known backend names only" do
    assert Server.model_id_from_env("claude") == :claude_api
    assert Server.model_id_from_env("claude_api") == :claude_api
    assert Server.model_id_from_env("codex") == :codex
    assert Server.model_id_from_env("gemini") == :gemini
    assert Server.model_id_from_env("gpt-99") == nil
    assert Server.model_id_from_env(nil) == nil
  end

  defp run_server(lines, model) do
    {:ok, input} = StringIO.open(Enum.join(lines, "\n") <> "\n")
    {:ok, output} = StringIO.open("")

    :ok =
      Server.run(
        input: input,
        output: output,
        model: model,
        new_session_id: fn -> "sess_test" end
      )

    {_in, written} = StringIO.contents(output)

    written
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      {:ok, frame} = Json.decode(line)
      frame
    end)
  end

  defp model(run) do
    %Model{id: :fake, label: "fake", kind: :cli, status: :ready, run: run}
  end
end
