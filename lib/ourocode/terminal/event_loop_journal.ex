defmodule Ourocode.Terminal.EventLoopJournal do
  @moduledoc """
  Journal persistence boundary for terminal event-loop input events.
  """

  alias Ourocode.Journal

  @spec append(String.t() | nil, map()) :: :ok | {:error, term()}
  def append(nil, _event), do: :ok

  def append(journal_path, event) when is_binary(journal_path) and is_map(event) do
    Journal.append(journal_path, event)
  end

  @spec persist(String.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def persist(nil, event) when is_map(event), do: {:ok, event}

  def persist(journal_path, event) when is_binary(journal_path) and is_map(event) do
    with {:ok, journaled_event} <- Journal.append_returning_event(journal_path, event) do
      {:ok, Map.put(event, :event_seq, journaled_event.event_seq)}
    end
  end
end
