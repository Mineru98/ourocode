defmodule Ourocode.Journal.CleanupEventType do
  @moduledoc """
  Classifies journal event types relevant to cleanup recovery.
  """

  alias Ourocode.Journal.CleanupEventFields, as: Fields

  @cleanup_types MapSet.new([:transport_cleanup, :stream_cleanup])
  @orphan_candidate_types MapSet.new([
                            :child_pane_registered,
                            :child_pane_opened,
                            :child_pane_focused,
                            :child_pane_updated
                          ])
  @completion_types MapSet.new([:child_pane_completed, :child_pane_cancelled])
  @failure_types MapSet.new([
                   :parent_call_failed,
                   :parent_call_write_failed,
                   :transport_failed,
                   :transport_decode_failed
                 ])

  @type category :: :cleanup | :orphan_candidate | :completion | :failure

  @spec category(map()) :: {:ok, category(), atom()} | :error
  def category(event) when is_map(event) do
    with {:ok, type} <- type(event),
         {:ok, category} <- category_for_type(type) do
      {:ok, category, type}
    end
  end

  @spec type(map()) :: {:ok, atom()} | :error
  def type(event) when is_map(event) do
    case Fields.value(event, :type) || Fields.value(event, :event_type) do
      type when is_atom(type) ->
        if known?(type), do: {:ok, type}, else: :error

      type when is_binary(type) ->
        known_type(String.trim(type))

      _type ->
        :error
    end
  end

  defp category_for_type(type) do
    cond do
      MapSet.member?(@cleanup_types, type) -> {:ok, :cleanup}
      MapSet.member?(@orphan_candidate_types, type) -> {:ok, :orphan_candidate}
      MapSet.member?(@completion_types, type) -> {:ok, :completion}
      MapSet.member?(@failure_types, type) -> {:ok, :failure}
      true -> :error
    end
  end

  defp known_type(type) do
    known_event_types()
    |> Enum.find_value(:error, fn known ->
      if Atom.to_string(known) == type, do: {:ok, known}
    end)
  end

  defp known?(type), do: MapSet.member?(known_event_types(), type)

  defp known_event_types do
    @cleanup_types
    |> MapSet.union(@orphan_candidate_types)
    |> MapSet.union(@completion_types)
    |> MapSet.union(@failure_types)
  end
end
