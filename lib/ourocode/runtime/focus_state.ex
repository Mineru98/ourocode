defmodule Ourocode.Runtime.FocusState do
  @moduledoc """
  Data-only focus state model for terminal pane steering.

  The runtime owns the focus state. Terminal input and slash-command layers can
  request a pane focus change, but this module validates the pane id against the
  current pane model before producing an updated state.
  """

  alias Ourocode.Runtime.FocusPaneModel

  @type pane_id :: atom() | String.t()

  @type t :: %{
          required(:focused_pane) => pane_id(),
          required(:steering_target) => atom(),
          optional(:steering_target_pane_id) => pane_id(),
          optional(:steering_target_session_id) => String.t() | nil,
          optional(:steering_target_kind) => atom(),
          required(:route) => atom(),
          optional(:previous_focused_pane) => pane_id() | nil,
          optional(:focused_at_ms) => integer(),
          optional(:history) => [map()]
        }

  @type focused_child_session :: %{
          required(:pane_id) => pane_id(),
          required(:session_id) => String.t(),
          required(:child_id) => String.t(),
          required(:kind) => atom(),
          required(:pane) => map()
        }

  @doc """
  Returns the initial terminal focus state.
  """
  @spec new() :: t()
  def new do
    %{
      focused_pane: :task_prompt,
      steering_target: :parent,
      steering_target_pane_id: :task_prompt,
      steering_target_session_id: nil,
      steering_target_kind: :prompt_input,
      route: :terminal_input_loop,
      history: []
    }
  end

  @doc """
  Updates focus when `target_pane_id` exists in the pane model.
  """
  @spec focus_pane(t(), pane_id(), map(), keyword() | map()) ::
          {:ok, t(), map() | nil} | {:error, {:unknown_pane, pane_id()}, t()}
  def focus_pane(focus_state, target_pane_id, pane_model, options \\ [])

  def focus_pane(focus_state, target_pane_id, pane_model, options)
      when is_map(focus_state) and is_map(pane_model) do
    with {:ok, pane_id} <- FocusPaneModel.resolve_pane_id(target_pane_id, pane_model) do
      options = Map.new(options)
      previous = Map.get(focus_state, :focused_pane)

      if previous == pane_id do
        {:ok, focus_state, nil}
      else
        occurred_at_ms = Map.get(options, :occurred_at_ms, System.system_time(:millisecond))
        steering_target = FocusPaneModel.steering_target(pane_id)

        target_metadata =
          FocusPaneModel.steering_target_metadata(pane_id, pane_model, steering_target)

        event = %{
          type: :focus_state_updated,
          event_type: :focus_state_updated,
          source: :pane_model,
          requested_pane_id: target_pane_id,
          previous_focused_pane: previous,
          focused_pane: pane_id,
          steering_target: steering_target,
          steering_target_pane_id: target_metadata.pane_id,
          steering_target_session_id: target_metadata.session_id,
          steering_target_kind: target_metadata.kind,
          occurred_at_ms: occurred_at_ms
        }

        updated =
          focus_state
          |> Map.put(:focused_pane, pane_id)
          |> Map.put(:previous_focused_pane, previous)
          |> Map.put(:steering_target, event.steering_target)
          |> Map.put(:steering_target_pane_id, event.steering_target_pane_id)
          |> Map.put(:steering_target_session_id, event.steering_target_session_id)
          |> Map.put(:steering_target_kind, event.steering_target_kind)
          |> Map.put(:route, :focused_pane)
          |> Map.put(:focused_at_ms, occurred_at_ms)
          |> append_history(event)

        {:ok, updated, event}
      end
    else
      :error -> {:error, {:unknown_pane, target_pane_id}, focus_state}
    end
  end

  def focus_pane(focus_state, target_pane_id, _pane_model, _options) do
    {:error, {:unknown_pane, target_pane_id}, focus_state}
  end

  @doc """
  Returns true when the pane id is present in the pane model.
  """
  @spec valid_pane?(pane_id(), map()) :: boolean()
  def valid_pane?(target_pane_id, pane_model) when is_map(pane_model) do
    FocusPaneModel.valid_pane?(target_pane_id, pane_model)
  end

  def valid_pane?(_target_pane_id, _pane_model), do: false

  @doc """
  Resolves the concrete child session currently targeted by focus state.

  Aggregate child containers such as `:children` are child steering targets, but
  they are not a concrete child session until focus points at a pane with a
  resolvable child/session id.
  """
  @spec focused_child_session(t(), map()) ::
          {:ok, focused_child_session()}
          | {:error, :no_focused_child_session | :focused_child_session_pane_not_found}
  def focused_child_session(focus_state, pane_model)
      when is_map(focus_state) and is_map(pane_model) do
    focused_pane = Map.get(focus_state, :focused_pane)

    with {:ok, pane_id} <- FocusPaneModel.resolve_pane_id(focused_pane, pane_model),
         :child <- FocusPaneModel.steering_target(pane_id),
         pane <- FocusPaneModel.pane_entry(pane_id, pane_model) || %{},
         session_id when is_binary(session_id) and session_id != "" <-
           FocusPaneModel.child_session_id(pane, pane_id, :child) do
      {:ok,
       %{
         pane_id: pane_id,
         session_id: session_id,
         child_id: session_id,
         kind: Map.get(pane, :kind) || Map.get(pane, "kind") || :child_session,
         pane: pane
       }}
    else
      :error -> {:error, :focused_child_session_pane_not_found}
      _not_concrete_child -> {:error, :no_focused_child_session}
    end
  end

  def focused_child_session(_focus_state, _pane_model) do
    {:error, :focused_child_session_pane_not_found}
  end

  defp append_history(state, event) do
    history =
      state
      |> Map.get(:history, [])
      |> List.wrap()

    Map.put(state, :history, [event | history])
  end
end
