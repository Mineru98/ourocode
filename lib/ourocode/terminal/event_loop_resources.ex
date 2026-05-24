defmodule Ourocode.Terminal.EventLoopResources do
  @moduledoc """
  Resource release guard for terminal event loop shutdown.
  """

  @spec release_active(map()) :: :ok | {:error, {:resource_release_failed, term()}}
  def release_active(state) when is_map(state) do
    case state.on_release_resources.(state.startup_result, state) do
      :ok -> :ok
      {:ok, _released} -> :ok
      {:error, reason} -> {:error, {:resource_release_failed, reason}}
      other -> {:error, {:resource_release_failed, {:invalid_result, other}}}
    end
  rescue
    exception ->
      {:error,
       {:resource_release_failed,
        {:exception, exception.__struct__, Exception.message(exception)}}}
  catch
    kind, reason ->
      {:error, {:resource_release_failed, {:caught, kind, reason}}}
  end
end
