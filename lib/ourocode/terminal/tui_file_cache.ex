defmodule Ourocode.Terminal.TuiFileCache do
  @moduledoc """
  Async project file cache policy for TUI file mention suggestions.
  """

  alias Ourocode.Terminal.FileDiscovery

  @spec get_or_start(pid(), pid(), (-> [String.t()])) :: [String.t()]
  def get_or_start(state, owner, discover \\ &FileDiscovery.discover/0)
      when is_pid(state) and is_pid(owner) and is_function(discover, 0) do
    case Agent.get(state, & &1.file_cache) do
      files when is_list(files) ->
        files

      :loading ->
        []

      _none ->
        start(state, owner, discover)
        []
    end
  end

  @spec put(pid(), [String.t()]) :: :ok
  def put(state, files) when is_pid(state) and is_list(files) do
    Agent.update(state, &%{&1 | file_cache: files})
  end

  defp start(state, owner, discover) do
    if mark_loading(state) do
      _ =
        Task.start(fn ->
          send(owner, {:file_cache_ready, discover.()})
        end)
    end

    :ok
  end

  defp mark_loading(state) do
    Agent.get_and_update(state, fn s ->
      case s.file_cache do
        nil -> {true, %{s | file_cache: :loading}}
        _other -> {false, s}
      end
    end)
  end
end
