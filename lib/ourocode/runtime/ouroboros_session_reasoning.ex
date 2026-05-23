defmodule Ourocode.Runtime.OuroborosSessionReasoning do
  @moduledoc false

  @max_lines 12

  @doc false
  def load(session_id) when is_binary(session_id) do
    session_id
    |> session_path()
    |> read_state()
    |> reasoning_from_state(session_id)
  end

  def load(_session_id), do: {[], %{}}

  @doc false
  def load_activity_context(session_id) when is_binary(session_id) do
    session_id
    |> session_path()
    |> read_state()
    |> activity_context_from_state()
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

  defp reasoning_from_state(state, _fallback_session_id) when state == %{},
    do: {[], %{}}

  defp reasoning_from_state(%{} = state, fallback_session_id) do
    rounds = value(state, "rounds") || []
    answered_rounds = Enum.count(rounds, &answered_round?/1)
    total_rounds = length(rounds)
    pending? = pending_question?(rounds)
    phase = phase(value(state, "status"), pending?, answered_rounds, total_rounds)
    question = last_question(rounds)

    reasoning_state =
      %{
        "phase" => phase,
        "next_action" => next_action(value(state, "status"), pending?),
        "session_id" => value(state, "interview_id") || fallback_session_id,
        "answered_rounds" => answered_rounds,
        "total_rounds" => total_rounds,
        "pending_question" => pending?,
        "is_brownfield" => value(state, "is_brownfield"),
        "ambiguity_score" => value(state, "ambiguity_score"),
        "ambiguity_breakdown" => value(state, "ambiguity_breakdown"),
        "seed_ready" => seed_ready?(state),
        "completion_candidate_streak" => value(state, "completion_candidate_streak"),
        "status" => value(state, "status"),
        "question_chars" => question_chars(question),
        "source" => "session_state"
      }
      |> reject_nil_values()

    {lines_from_state(reasoning_state), reasoning_state}
  end

  defp activity_context_from_state(state) when state == %{}, do: %{}

  defp activity_context_from_state(%{} = state) do
    rounds = value(state, "rounds") || []

    %{
      session_id: value(state, "interview_id"),
      initial_context: preview(value(state, "initial_context")),
      questions: question_previews(rounds)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
    |> Map.new()
  end

  defp answered_round?(%{} = round) do
    case value(round, "user_response") do
      response when is_binary(response) -> String.trim(response) != ""
      nil -> false
      _other -> true
    end
  end

  defp answered_round?(_round), do: false

  defp pending_question?([]), do: false

  defp pending_question?(rounds) do
    rounds
    |> List.last()
    |> case do
      %{} = round -> not answered_round?(round)
      _other -> false
    end
  end

  defp phase("completed", _pending?, _answered, _total), do: "complete"
  defp phase("failed", _pending?, _answered, _total), do: "failed"
  defp phase(_status, true, _answered, _total), do: "question"
  defp phase(_status, _pending?, 0, 0), do: "start"
  defp phase(_status, _pending?, answered, total) when answered >= total, do: "answer"
  defp phase(_status, _pending?, _answered, _total), do: "in_progress"

  defp next_action("completed", _pending?), do: "generate seed or run next step"
  defp next_action("failed", _pending?), do: "inspect failure and retry"
  defp next_action(_status, true), do: "ask user to answer pending question"
  defp next_action(_status, _pending?), do: "wait for next interview question"

  defp seed_ready?(state) do
    case value(state, "status") do
      "completed" -> true
      _other -> value(state, "seed_ready")
    end
  end

  defp last_question([]), do: nil

  defp last_question(rounds) do
    rounds
    |> List.last()
    |> case do
      %{} = round -> value(round, "question")
      _other -> nil
    end
  end

  defp question_previews(rounds) when is_list(rounds) do
    rounds
    |> Enum.reduce(%{}, fn
      %{} = round, acc ->
        round_number = value(round, "round_number")
        question = preview(value(round, "question"))

        if is_integer(round_number) and is_binary(question) and question != "",
          do: Map.put(acc, round_number, question),
          else: acc

      _round, acc ->
        acc
    end)
  end

  defp question_previews(_rounds), do: %{}

  defp preview(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate(96)
  end

  defp preview(_text), do: nil

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    text
    |> String.slice(0, max)
    |> String.trim()
    |> Kernel.<>("...")
  end

  defp question_chars(question) when is_binary(question), do: String.length(question)
  defp question_chars(_question), do: nil

  defp lines_from_state(state) do
    [
      line(state, "phase", "phase"),
      line(state, "session_id", "session"),
      rounds_line(state),
      line(state, "pending_question", "pending"),
      line(state, "is_brownfield", "brownfield"),
      line(state, "ambiguity_score", "ambiguity"),
      line(state, "seed_ready", "seed-ready"),
      line(state, "completion_candidate_streak", "stability"),
      line(state, "status", "status"),
      line(state, "question_chars", "question_chars"),
      line(state, "next_action", "next"),
      line(state, "source", "source")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.take(@max_lines)
  end

  defp rounds_line(state) do
    answered = value(state, "answered_rounds")
    total = value(state, "total_rounds")

    if is_integer(answered) and is_integer(total),
      do: "rounds: #{answered} answered / #{total} total",
      else: nil
  end

  defp line(state, "pending_question", label) do
    case value(state, "pending_question") do
      true -> "#{label}: waiting for user answer"
      _other -> nil
    end
  end

  defp line(state, key, label) do
    case value(state, key) do
      value when value in [nil, "", []] -> nil
      value -> "#{label}: #{format_value(value)}"
    end
  end

  defp format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: to_string(value)

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, "", []] end)
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, safe_atom(key))
    end
  end

  defp value(_map, _key), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
