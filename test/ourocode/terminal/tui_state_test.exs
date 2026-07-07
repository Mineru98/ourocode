defmodule Ourocode.Terminal.TuiStateTest do
  use ExUnit.Case, async: false

  alias Ourocode.Terminal.{PromptStore, TuiState}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "ourocode-tui-state-#{System.unique_integer([:positive])}")

    previous = System.get_env("OUROCODE_STATE_DIR")
    System.put_env("OUROCODE_STATE_DIR", dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("OUROCODE_STATE_DIR", previous),
        else: System.delete_env("OUROCODE_STATE_DIR")

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "start_link loads draft and history from prompt store", %{dir: dir} do
    PromptStore.save_draft("ooo interview", state_dir: dir)
    PromptStore.append_history("ooo seed", state_dir: dir)

    state = TuiState.start_link()

    assert TuiState.buffer(state) == "ooo interview"
    assert TuiState.cursor(state) == String.length("ooo interview")

    assert Agent.get(state, & &1.history) == ["ooo seed"]
  end

  test "basic accessors update model, mode, scroll, size, and transient flags" do
    state = TuiState.start_link()

    assert TuiState.mode(state) == :normal
    assert TuiState.scroll_off(state) == 0

    assert :ok = TuiState.put_mode(state, :palette)
    assert :ok = TuiState.put_pidx(state, 3)
    assert :ok = TuiState.put_scroll(state, -10)
    assert :ok = TuiState.scroll_by(state, 5)
    assert :ok = TuiState.put_size(state, {80, 24})
    assert :ok = TuiState.set_streaming(state, true)
    assert :ok = TuiState.toggle_key_help(state)
    assert :ok = TuiState.bump_tick(state)
    assert :ok = TuiState.put_model_id(state, :codex)
    assert :ok = TuiState.put_login(state, %{code: "1234"})

    assert TuiState.mode(state) == :palette
    assert TuiState.pidx(state) == 3
    assert TuiState.scroll_off(state) == 5
    assert TuiState.size(state) == {80, 24}
    assert TuiState.streaming?(state)
    assert TuiState.key_help?(state)
    assert TuiState.tick(state) == 1
    assert TuiState.login(state) == %{code: "1234"}

    assert Agent.get(state, & &1.model_id) == :codex
    assert Agent.get(state, & &1.model_cache) == nil
  end

  test "provider id and provider-specific model slug are stored separately" do
    state = TuiState.start_link()

    assert :ok = TuiState.put_model_id(state, :codex)
    assert :ok = TuiState.put_provider_model_slug(state, :codex, " gpt-5.5 ")

    assert Agent.get(state, & &1.model_id) == :codex
    assert TuiState.provider_model_slug(state, :codex) == "gpt-5.5"

    assert :ok =
             TuiState.put_provider_model_slug(state, :codex, " test-codex-model ",
               allow_custom?: true
             )

    assert Agent.get(state, & &1.model_id) == :codex
    assert TuiState.provider_model_slug(state, :codex) == "test-codex-model"
  end

  test "changing provider model slug invalidates model cache and rejects malformed slugs" do
    state = TuiState.start_link()

    Agent.update(state, fn current ->
      %{current | model_id: :codex, model_cache: %{id: :codex, model: :cached, expires_at: 123}}
    end)

    assert :ok = TuiState.put_provider_model_slug(state, :codex, "gpt-5.5")
    assert Agent.get(state, & &1.model_cache) == nil

    assert {:error, :blank_slug} = TuiState.put_provider_model_slug(state, :codex, " ")

    assert {:error, :unknown_provider} =
             TuiState.put_provider_model_slug(state, :unknown, "gpt-5.5")

    assert {:error, :invalid_slug} = TuiState.put_provider_model_slug(state, :codex, 123)
  end

  test "edit, take_buffer, leftover, and notification helpers mutate state" do
    state = TuiState.start_link()

    assert :ok = TuiState.edit_buffer(state, %{key: :char, char: "A"})
    assert TuiState.buffer(state) == "A"
    assert TuiState.cursor(state) == 1

    assert :ok = TuiState.push_notification(state, "saved", 1_000)
    assert TuiState.notifications(state) == ["saved"]

    assert :ok = TuiState.put_leftover(state, "abc")
    assert TuiState.take_leftover(state) == "abc"
    assert TuiState.take_leftover(state) == ""

    assert TuiState.take_buffer(state) == "A"
    assert TuiState.buffer(state) == ""
    assert TuiState.cursor(state) == 0
  end

  test "history navigation records and moves through prompts" do
    state = TuiState.start_link()

    assert :ok = TuiState.remember_history(state, "ooo interview")
    assert :ok = TuiState.remember_history(state, "ooo seed")

    assert :ok = TuiState.move_history(state, -1)
    assert TuiState.buffer(state) == "ooo seed"

    assert :ok = TuiState.move_history(state, -1)
    assert TuiState.buffer(state) == "ooo interview"

    assert :ok = TuiState.reset_history_cursor(state)
    assert Agent.get(state, & &1.history_index) == 0
    assert TuiState.buffer(state) == "ooo interview"
  end

  test "escape clear arms first and clears input on second press" do
    state = TuiState.start_link()
    TuiState.edit_buffer(state, %{key: :char, char: "x"})

    assert :ok = TuiState.handle_escape_clear(state)
    assert TuiState.buffer(state) == "x"
    assert ["Esc again to clear input"] = TuiState.notifications(state)

    assert :ok = TuiState.handle_escape_clear(state)
    assert TuiState.buffer(state) == ""
    assert hd(TuiState.notifications(state)) == "input cleared"
  end
end
