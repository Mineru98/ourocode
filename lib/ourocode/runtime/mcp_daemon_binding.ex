defmodule Ourocode.Runtime.McpDaemonBinding do
  @moduledoc """
  Maintains the MCP daemon handle and related Ouroboros log source state.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Catalog
  alias Ourocode.Runtime.McpDaemon
  alias Ourocode.Runtime.OuroborosLogTailer

  @spec ensure(pid(), Model.t() | term()) :: {:ok, String.t()}
  def ensure(agent, %Model{} = model) when is_pid(agent) do
    requested_backend = llm_backend(model)

    {handle, current_backend} =
      Agent.get(agent, fn state ->
        {Map.get(state, :mcp_daemon), Map.get(state, :mcp_llm_backend)}
      end)

    if reusable?(handle, current_backend, requested_backend) do
      {:ok, Map.get(handle, :url, default_url())}
    else
      McpDaemon.stop(handle)
      {:ok, new_handle} = McpDaemon.maybe_start(llm_backend: requested_backend)

      Agent.update(agent, fn state ->
        state
        |> Map.put(:mcp_daemon, new_handle)
        |> Map.put(:mcp_llm_backend, requested_backend)
        |> reset_log_sources(new_handle)
      end)

      {:ok, Map.get(new_handle, :url, default_url())}
    end
  end

  def ensure(agent, _model) when is_pid(agent), do: ensure(agent, Catalog.default())

  @spec reusable?(map() | nil, String.t() | nil, String.t() | nil) :: boolean()
  def reusable?(nil, _current_backend, _requested_backend), do: false
  def reusable?(%{mode: :external}, _current_backend, _requested_backend), do: true

  def reusable?(_handle, current_backend, requested_backend),
    do: current_backend == requested_backend

  @spec reset_log_sources(map(), map() | nil) :: map()
  def reset_log_sources(state, handle) when is_map(state) do
    paths =
      [
        Map.get(handle || %{}, :log_path),
        OuroborosLogTailer.canonical_log_path()
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    offsets = Map.new(paths, &{&1, OuroborosLogTailer.file_size(&1)})

    state
    |> Map.put(:ouroboros_log_paths, paths)
    |> Map.put(:ouroboros_log_offsets, offsets)
    |> Map.put(:ouroboros_activity, [])
  end

  @spec llm_backend(Model.t() | term()) :: String.t() | nil
  def llm_backend(%Model{id: id}) when id in [:codex, :codex_cli], do: "codex"
  def llm_backend(%Model{id: :claude}), do: "claude_code"
  def llm_backend(_model), do: System.get_env("OUROCODE_MCP_LLM_BACKEND")

  defp default_url do
    System.get_env("OUROCODE_MCP_URL") || "http://127.0.0.1:4000/mcp"
  end
end
