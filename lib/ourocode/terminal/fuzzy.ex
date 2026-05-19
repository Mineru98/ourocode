defmodule Ourocode.Terminal.Fuzzy do
  @moduledoc """
  Small deterministic fuzzy scorer for terminal discovery surfaces.

  The score is intentionally simple: exact/prefix/substring matches rank first,
  then ordered acronym/subsequence matches, then edit-distance near misses. A
  lower score is better.
  """

  @type candidate :: {String.t(), term()}

  @doc "Ranks `{text, payload}` candidates for a user query."
  @spec rank([candidate()], String.t(), keyword()) :: [term()]
  def rank(candidates, query, opts \\ []) when is_list(candidates) and is_binary(query) do
    limit = Keyword.get(opts, :limit)
    normalized = normalize(query)

    candidates
    |> Enum.with_index()
    |> Enum.flat_map(fn {{text, payload}, order} ->
      case score(normalize(text), normalized) do
        nil -> []
        score -> [{score, order, payload}]
      end
    end)
    |> Enum.sort_by(fn {score, order, _payload} -> {score, order} end)
    |> Enum.map(fn {_score, _order, payload} -> payload end)
    |> maybe_limit(limit)
  end

  @doc "Returns a score for `candidate` against `query`, or nil when too far."
  @spec score(String.t(), String.t()) :: non_neg_integer() | nil
  def score(_candidate, ""), do: 0

  def score(candidate, query) when is_binary(candidate) and is_binary(query) do
    candidate = normalize(candidate)
    query = normalize(query)

    cond do
      candidate == query ->
        0

      String.starts_with?(candidate, query) ->
        10 + String.length(candidate) - String.length(query)

      String.contains?(candidate, query) ->
        30 + substring_offset(candidate, query)

      subsequence?(candidate, query) ->
        60 + String.length(candidate) - String.length(query)

      true ->
        distance = edit_distance(candidate, query)
        threshold = max(2, div(String.length(query), 2))
        if distance <= threshold, do: 120 + distance * 10 + String.length(candidate), else: nil
    end
  end

  def score(_candidate, _query), do: nil

  defp normalize(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9가-힣_@\/\.\-]+/u, "")
  end

  defp substring_offset(candidate, query) do
    candidate
    |> String.split(query, parts: 2)
    |> hd()
    |> String.length()
  end

  defp subsequence?(candidate, query) do
    chars = String.graphemes(candidate)

    query
    |> String.graphemes()
    |> Enum.reduce_while(chars, fn q, remaining ->
      case Enum.drop_while(remaining, &(&1 != q)) do
        [] -> {:halt, :missing}
        [_found | rest] -> {:cont, rest}
      end
    end)
    |> Kernel.!==(:missing)
  end

  defp edit_distance(a, b) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)
    initial = Enum.to_list(0..length(b_chars))

    a_chars
    |> Enum.with_index(1)
    |> Enum.reduce(initial, fn {ca, i}, prev ->
      {row, _left, _diag} =
        b_chars
        |> Enum.with_index(1)
        |> Enum.reduce({[i], i, i - 1}, fn {cb, j}, {acc, left, diag} ->
          up = Enum.at(prev, j)
          cost = if ca == cb, do: 0, else: 1
          value = min(min(left + 1, up + 1), diag + cost)
          {[value | acc], value, up}
        end)

      Enum.reverse(row)
    end)
    |> List.last()
  end

  defp maybe_limit(items, nil), do: items
  defp maybe_limit(items, limit) when is_integer(limit) and limit > 0, do: Enum.take(items, limit)
  defp maybe_limit(items, _limit), do: items
end
