defmodule Ourocode.Terminal.FocusNavigation do
  @moduledoc false

  alias Ourocode.Runtime.FocusState

  @focus_commands ["/pane", "/focus", "/focus-pane"]

  @spec default_pane_model() :: map()
  def default_pane_model do
    %{
      panes: %{
        task_prompt: %{id: :task_prompt, kind: :prompt_input},
        parent: %{id: :parent, kind: :parent_session},
        children: %{id: :children, kind: :child_sessions},
        queue: %{id: :queue, kind: :queued_notifications},
        status: %{id: :status, kind: :status_area},
        wonder_tool: %{id: :wonder_tool, kind: :wonder_tool}
      },
      open: [:task_prompt, :parent, :children, :queue, :status, :wonder_tool]
    }
  end

  @spec keyboard_focus_bindings(map()) :: map()
  def keyboard_focus_bindings(options) when is_map(options) do
    defaults = %{
      "tab" => :children,
      "shift_tab" => :parent,
      "ctrl_p" => :parent,
      "ctrl_c" => :children,
      "ctrl_q" => :queue,
      "ctrl_s" => :status,
      "ctrl_w" => :wonder_tool
    }

    configured =
      options
      |> Map.get(:keyboard_focus_bindings, %{})
      |> Enum.into(%{}, fn {key, target_pane_id} -> {normalized_key(key), target_pane_id} end)

    Map.merge(defaults, configured)
  end

  @spec resolve_keyboard_focus_target(map(), map()) :: {:ok, term()} | :ignore
  def resolve_keyboard_focus_target(key_input, bindings)
      when is_map(key_input) and is_map(bindings) do
    cond do
      not keyboard_input?(key_input) ->
        :ignore

      Map.has_key?(key_input, :target_pane_id) ->
        {:ok, Map.fetch!(key_input, :target_pane_id)}

      Map.has_key?(key_input, :target_pane) ->
        {:ok, Map.fetch!(key_input, :target_pane)}

      Map.has_key?(key_input, :pane_id) ->
        {:ok, Map.fetch!(key_input, :pane_id)}

      true ->
        key = normalized_key(Map.get(key_input, :key))

        case Map.fetch(bindings, key) do
          {:ok, target_pane_id} -> {:ok, target_pane_id}
          :error -> :ignore
        end
    end
  end

  def resolve_keyboard_focus_target(_key_input, _bindings), do: :ignore

  @spec command_focus_target(map()) :: {:ok, term()} | :ignore
  def command_focus_target(%{command: command, args: [target_pane_id | _args]})
      when command in @focus_commands do
    {:ok, target_pane_id}
  end

  def command_focus_target(%{command: command, args: args})
      when command in @focus_commands and args in [[], nil] do
    :ignore
  end

  def command_focus_target(_command_event), do: :ignore

  @spec same_pane?(term(), term(), map()) :: boolean()
  def same_pane?(focused_pane, target_pane_id, pane_model) do
    if FocusState.valid_pane?(target_pane_id, pane_model) do
      pane_key(focused_pane) == pane_key(target_pane_id)
    else
      false
    end
  end

  @spec keyboard_focus_event(map(), map()) :: map()
  def keyboard_focus_event(focus_event, key_input) do
    focus_event
    |> Map.put(:source, :terminal_keyboard)
    |> Map.put(:input_kind, :keyboard)
    |> Map.put(:key, Map.get(key_input, :key))
    |> Map.put(:raw_input, key_input)
    |> Map.put(:payload, %{
      focused_pane: focus_event.focused_pane,
      previous_focused_pane: focus_event.previous_focused_pane,
      steering_target: focus_event.steering_target,
      steering_target_pane_id: Map.get(focus_event, :steering_target_pane_id),
      steering_target_session_id: Map.get(focus_event, :steering_target_session_id),
      steering_target_kind: Map.get(focus_event, :steering_target_kind),
      key: Map.get(key_input, :key),
      raw_input: key_input
    })
  end

  @spec keyboard_focus_error_event(map(), term()) :: map()
  def keyboard_focus_error_event(key_input, reason) do
    %{
      type: :keyboard_focus_failed,
      event_type: :keyboard_focus_failed,
      source: :terminal_keyboard,
      input_kind: :keyboard,
      recoverable?: true,
      reason: reason,
      key: Map.get(key_input, :key),
      raw_input: key_input,
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        reason: reason,
        key: Map.get(key_input, :key),
        raw_input: key_input
      }
    }
  end

  @spec command_focus_event(map(), map()) :: map()
  def command_focus_event(focus_event, command_event) do
    focus_event
    |> Map.put(:source, :terminal_command)
    |> Map.put(:input_kind, :slash_command)
    |> Map.put(:command, command_event.command)
    |> Map.put(:args, command_event.args)
    |> Map.put(:raw_input, command_event.raw_input)
    |> Map.put(:payload, %{
      command: command_event.command,
      args: command_event.args,
      raw_input: command_event.raw_input,
      focused_pane: focus_event.focused_pane,
      previous_focused_pane: focus_event.previous_focused_pane,
      steering_target: focus_event.steering_target,
      steering_target_pane_id: Map.get(focus_event, :steering_target_pane_id),
      steering_target_session_id: Map.get(focus_event, :steering_target_session_id),
      steering_target_kind: Map.get(focus_event, :steering_target_kind)
    })
  end

  @spec pane_key(term()) :: String.t()
  def pane_key(pane_id) when is_atom(pane_id), do: Atom.to_string(pane_id)
  def pane_key(pane_id) when is_binary(pane_id), do: pane_id
  def pane_key(pane_id), do: inspect(pane_id)

  defp keyboard_input?(%{input_kind: :keyboard}), do: true
  defp keyboard_input?(%{type: :keyboard_input}), do: true
  defp keyboard_input?(%{key: _key}), do: true
  defp keyboard_input?(_key_input), do: false

  defp normalized_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalized_key()

  defp normalized_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

  defp normalized_key(key), do: inspect(key)
end
