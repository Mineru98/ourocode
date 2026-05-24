defmodule Ourocode.WonderTool.OptionSelection do
  @moduledoc """
  Resolves extracted wonderTool selection values against question options.
  """

  alias Ourocode.WonderTool.SelectionPayload

  @spec normalize(map(), map() | list() | integer() | String.t()) ::
          {:ok, list()} | {:error, term()}
  def normalize(question, selection_payload) do
    selections =
      case SelectionPayload.extract_selections(selection_payload) do
        [] -> other_selection_from_payload(question, selection_payload)
        values -> values
      end

    cond do
      selections == [] ->
        {:error, :selection_required}

      multi_select?(question) ->
        {:ok, selections}

      match?([_one], selections) ->
        {:ok, selections}

      true ->
        {:error, {:exactly_one_selection_required, length(selections)}}
    end
  end

  @spec resolve(map(), list()) :: {:ok, [{pos_integer(), map()}]} | {:error, term()}
  def resolve(%{options: options}, selections) when is_list(options) do
    selections
    |> Enum.reduce_while({:ok, []}, fn selection, {:ok, acc} ->
      case resolve_option(options, selection) do
        {:ok, index, option} -> {:cont, {:ok, [{index, option} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, selected} ->
        selected =
          selected
          |> Enum.reverse()
          |> Enum.uniq_by(fn {index, _option} -> index end)

        if selected == [], do: {:error, :selection_required}, else: {:ok, selected}

      error ->
        error
    end
  end

  def resolve(_question, _selections), do: {:error, :options_required}

  @spec multi_select?(map()) :: boolean()
  def multi_select?(question), do: Map.get(question, :multi_select?, false) == true

  @spec other_option(map()) :: map() | nil
  def other_option(%{options: options}) when is_list(options) do
    Enum.find(options, &other_option?/1)
  end

  def other_option(_question), do: nil

  @spec other_option?(term()) :: boolean()
  def other_option?(option) when is_map(option) do
    Map.get(option, :other?, false) == true or
      normalize_label(Map.get(option, :label)) in ["other", "기타"]
  end

  def other_option?(_option), do: false

  @spec normalize_label(term()) :: String.t() | nil
  def normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  def normalize_label(_label), do: nil

  defp other_selection_from_payload(question, selection_payload) do
    with text when is_binary(text) <- SelectionPayload.free_text(selection_payload),
         true <- String.trim(text) != "",
         %{label: label} <- other_option(question) do
      [label]
    else
      _other -> []
    end
  end

  defp resolve_option(options, selection) do
    options
    |> Enum.with_index(1)
    |> Enum.find(&option_matches_selection?(&1, selection))
    |> case do
      {option, index} -> {:ok, index, option}
      nil -> resolve_other_option(options, selection)
    end
  end

  defp resolve_other_option(options, selection) when is_binary(selection) do
    case Enum.find(Enum.with_index(options, 1), fn {option, _index} -> other_option?(option) end) do
      {option, index} -> {:ok, index, option}
      nil -> {:error, {:unknown_selected_option, selection}}
    end
  end

  defp resolve_other_option(_options, selection),
    do: {:error, {:unknown_selected_option, selection}}

  defp option_matches_selection?({_option, index}, selection) when is_integer(selection),
    do: index == selection

  defp option_matches_selection?({option, index}, selection) when is_binary(selection) do
    case Integer.parse(String.trim(selection)) do
      {parsed_index, ""} -> index == parsed_index
      _other -> normalize_label(Map.get(option, :label)) == normalize_label(selection)
    end
  end

  defp option_matches_selection?(_indexed_option, _selection), do: false
end
