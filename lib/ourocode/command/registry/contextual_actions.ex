defmodule Ourocode.Command.Registry.ContextualActions do
  @moduledoc """
  Context-sensitive command entries derived from terminal focus state.
  """

  alias Ourocode.Command.Registry.Builtin
  alias Ourocode.Runtime.FocusState

  @spec entries(keyword() | map()) :: [map()]
  def entries(context) do
    context = Map.new(context)
    focus_state = Map.get(context, :focus_state, FocusState.new())
    pane_model = Map.get(context, :pane_model, %{})

    case FocusState.focused_child_session(focus_state, pane_model) do
      {:ok, focused_child} ->
        [
          child_action_entry(Builtin.interrupt_definition(), focused_child,
            introduced_in: :interrupt_baseline,
            requires_metadata_key: :requires_focused_child_session?
          ),
          child_action_entry(Builtin.cancel_definition(), focused_child,
            introduced_in: :cancel_baseline,
            requires_metadata_key: :requires_focused_child_session?
          )
        ]

      {:error, _reason} ->
        []
    end
  end

  defp child_action_entry(definition, focused_child, options) do
    requires_metadata_key = Keyword.fetch!(options, :requires_metadata_key)

    definition
    |> Builtin.normalize!()
    |> put_in([:source_attribution, requires_metadata_key], true)
    |> put_in([:run_spec, :target], :focused_child_session)
    |> put_in([:run_spec, :child_session_id], focused_child.session_id)
    |> put_in([:run_spec, :child_pane_id], focused_child.pane_id)
    |> put_in([:metadata, :introduced_in], Keyword.fetch!(options, :introduced_in))
    |> put_in([:metadata, :contextual?], true)
    |> put_in([:metadata, requires_metadata_key], true)
    |> put_in([:metadata, :focused_child_session], %{
      pane_id: focused_child.pane_id,
      session_id: focused_child.session_id,
      child_id: focused_child.child_id,
      kind: focused_child.kind
    })
  end
end
