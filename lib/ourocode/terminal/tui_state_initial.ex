defmodule Ourocode.Terminal.TuiStateInitial do
  @moduledoc """
  Builds the initial Agent state for the interactive TUI.
  """

  alias Ourocode.Terminal.PromptStore

  @spec build() :: map()
  def build do
    draft = PromptStore.load_draft()

    %{
      buffer: draft,
      cursor: String.length(draft),
      leftover: "",
      prev_screen: nil,
      port: nil,
      inbuf: "",
      mode: :normal,
      pidx: 0,
      login: nil,
      streaming: false,
      key_help: false,
      tick: 0,
      size: {120, 40},
      model_id: nil,
      model_cache: nil,
      scroll: 0,
      wonder_nav: nil,
      history: PromptStore.load_history(),
      history_index: 0,
      history_draft: nil,
      file_cache: nil,
      ooo_cache: nil,
      ooo_cache_loaded_ms: nil,
      kill_ring: [],
      kill_index: 0,
      last_edit_was_kill: false,
      last_yank: nil,
      esc_armed_until: nil,
      notifications: []
    }
  end
end
