defmodule Ourocode.Runtime.FocusState do
  @moduledoc """
  Data-only focus state model for terminal pane steering.

  The runtime owns the focus state. Terminal input and slash-command layers can
  request a pane focus change, but this module validates the pane id against the
  current pane model before producing an updated state.
  """

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
    with {:ok, pane_id} <- resolve_pane_id(target_pane_id, pane_model) do
      options = Map.new(options)
      previous = Map.get(focus_state, :focused_pane)

      if previous == pane_id do
        {:ok, focus_state, nil}
      else
        occurred_at_ms = Map.get(options, :occurred_at_ms, System.system_time(:millisecond))
        steering_target = steering_target(pane_id)
        target_metadata = steering_target_metadata(pane_id, pane_model, steering_target)

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
    match?({:ok, _pane_id}, resolve_pane_id(target_pane_id, pane_model))
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

    with {:ok, pane_id} <- resolve_pane_id(focused_pane, pane_model),
         :child <- steering_target(pane_id),
         pane <- pane_entry(pane_id, pane_model) || %{},
         session_id when is_binary(session_id) and session_id != "" <-
           child_session_id(pane, pane_id, :child) do
      {:ok,
       %{
         pane_id: pane_id,
         session_id: session_id,
         child_id: session_id,
         kind: map_value(pane, :kind) || :child_session,
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

  defp resolve_pane_id(target_pane_id, pane_model) do
    pane_ids = pane_ids(pane_model)

    cond do
      MapSet.member?(pane_ids, target_pane_id) ->
        {:ok, target_pane_id}

      is_binary(target_pane_id) ->
        target_atom = safe_existing_atom(target_pane_id)

        if not is_nil(target_atom) and MapSet.member?(pane_ids, target_atom) do
          {:ok, target_atom}
        else
          :error
        end

      is_atom(target_pane_id) ->
        target_string = Atom.to_string(target_pane_id)

        if MapSet.member?(pane_ids, target_string) do
          {:ok, target_string}
        else
          :error
        end

      true ->
        :error
    end
  end

  defp pane_ids(pane_model) do
    open_pane_ids =
      pane_model
      |> Map.get(:open, [])
      |> List.wrap()
      |> Enum.flat_map(&resolve_open_pane_id(&1, pane_model))

    MapSet.new([:task_prompt | open_pane_ids])
  end

  defp resolve_open_pane_id(open_pane_id, pane_model) do
    case map_value(pane_model, :panes) || %{} do
      %{^open_pane_id => %{id: pane_id}} -> [pane_id]
      %{^open_pane_id => %{"id" => pane_id}} -> [pane_id]
      _panes -> [open_pane_id]
    end
  end

  defp steering_target_metadata(pane_id, pane_model, steering_target) do
    pane = pane_entry(pane_id, pane_model) || %{}

    %{
      pane_id: pane_id,
      session_id: child_session_id(pane, pane_id, steering_target),
      kind: map_value(pane, :kind) || steering_target
    }
  end

  defp pane_entry(pane_id, pane_model) do
    panes = map_value(pane_model, :panes) || %{}

    Enum.find_value(panes, fn
      {^pane_id, pane} when is_map(pane) ->
        pane

      {_key, %{id: ^pane_id} = pane} ->
        pane

      {_key, %{"id" => ^pane_id} = pane} ->
        pane

      {_key, _pane} ->
        nil
    end)
  end

  defp child_session_id(pane, pane_id, :child) when is_map(pane) do
    map_value(pane, :child_id) ||
      map_value(pane, :session_id) ||
      pane
      |> map_value(:external_ids)
      |> first_child_external_id() ||
      child_session_id(nil, pane_id, :child)
  end

  defp child_session_id(_pane, pane_id, :child) when is_binary(pane_id) do
    cond do
      String.starts_with?(pane_id, "child-session:") ->
        String.replace_prefix(pane_id, "child-session:", "")

      String.starts_with?(pane_id, "child-pane:") ->
        String.replace_prefix(pane_id, "child-pane:", "")

      true ->
        nil
    end
  end

  defp child_session_id(_pane, _pane_id, _steering_target), do: nil

  defp first_child_external_id(external_ids) when is_map(external_ids) do
    Enum.find_value(
      [
        {"childID", :childID},
        {"child_id", :child_id},
        {"session_id", :session_id},
        {"thread_id", :thread_id},
        {"native_session_id", :native_session_id}
      ],
      fn {string_key, atom_key} ->
        case Map.get(external_ids, string_key) || Map.get(external_ids, atom_key) do
          value when is_binary(value) and value != "" -> value
          _value -> nil
        end
      end
    )
  end

  defp first_child_external_id(_external_ids), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp safe_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp steering_target(:task_prompt), do: :parent
  defp steering_target(:parent), do: :parent
  defp steering_target("parent"), do: :parent
  defp steering_target(:children), do: :child
  defp steering_target("children"), do: :child
  defp steering_target(:queue), do: :queue
  defp steering_target("queue"), do: :queue
  defp steering_target(:status), do: :status
  defp steering_target("status"), do: :status
  defp steering_target(:wonder_tool), do: :wonder_tool
  defp steering_target("wonder_tool"), do: :wonder_tool

  defp steering_target(pane_id) when is_binary(pane_id) do
    cond do
      String.starts_with?(pane_id, "child-") -> :child
      String.starts_with?(pane_id, "child:") -> :child
      String.starts_with?(pane_id, "child-session:") -> :child
      String.starts_with?(pane_id, "child-pane:") -> :child
      String.starts_with?(pane_id, "parent-") -> :parent
      String.starts_with?(pane_id, "parent:") -> :parent
      String.starts_with?(pane_id, "parent-mcp:") -> :parent
      true -> :pane
    end
  end

  defp steering_target(_pane_id), do: :pane

  defp append_history(state, event) do
    history =
      state
      |> Map.get(:history, [])
      |> List.wrap()

    Map.put(state, :history, [event | history])
  end
end
