defmodule Ourocode.Runtime.OuroborosSessionReasoning do
  @moduledoc false

  alias Ourocode.Runtime.OuroborosSessionProjection

  @doc false
  def load(session_id) when is_binary(session_id) do
    session_id
    |> session_path()
    |> read_state()
    |> OuroborosSessionProjection.reasoning(session_id)
  end

  def load(_session_id), do: {[], %{}}

  @doc false
  def load_activity_context(session_id) when is_binary(session_id) do
    session_id
    |> session_path()
    |> read_state()
    |> OuroborosSessionProjection.activity_context()
  end

  def load_activity_context(_session_id), do: %{}

  @doc false
  def session_path(session_id) when is_binary(session_id) do
    Path.join([ouroboros_home(), "data", "interview_#{session_id}.json"])
  rescue
    _exception -> nil
  end

  def session_path(_session_id), do: nil

  defp ouroboros_home do
    System.get_env("OUROCODE_OUROBOROS_HOME") ||
      Path.join(System.user_home!(), ".ouroboros")
  end

  defp read_state(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = state} <- Ourocode.Json.decode(body) do
      state
    else
      _error -> %{}
    end
  rescue
    _exception -> %{}
  end

  defp read_state(_path), do: %{}
end
