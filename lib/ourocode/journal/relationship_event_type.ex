defmodule Ourocode.Journal.RelationshipEventType do
  @moduledoc """
  Classifies journal event types relevant to relationship recovery.
  """

  alias Ourocode.Journal.RelationshipEventFields, as: Fields

  @pane_lifecycle_types MapSet.new([
                          :child_pane_registered,
                          :child_pane_opened,
                          :child_pane_focused,
                          :child_pane_updated,
                          :child_pane_completed
                        ])

  @runtime_relationship_types MapSet.new([
                                :parent_call_started,
                                :parent_call_event,
                                :parent_call_result
                              ])

  @type category :: :pane_lifecycle | :runtime_relationship

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
      MapSet.member?(@pane_lifecycle_types, type) -> {:ok, :pane_lifecycle}
      MapSet.member?(@runtime_relationship_types, type) -> {:ok, :runtime_relationship}
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
    MapSet.union(@pane_lifecycle_types, @runtime_relationship_types)
  end
end
