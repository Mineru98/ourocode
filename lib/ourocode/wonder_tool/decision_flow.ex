defmodule Ourocode.WonderTool.DecisionFlow do
  @moduledoc """
  Data-only wonderTool decision, permission, and clarification flow boundary.

  The flow keeps prompt rendering and answer capture on the same normalized
  request. Terminal/UI code can render `rendered_prompt.lines`, collect one
  selection, then persist the returned `wonder_decision` to the local journal.
  """

  alias Ourocode.Dashboard.WonderToolPromptRenderer
  alias Ourocode.Journal
  alias Ourocode.WonderTool.{DecisionRequest, SelectionHandler}

  @type prepared :: %{
          required(:request) => DecisionRequest.t(),
          required(:rendered_prompt) => WonderToolPromptRenderer.rendered_prompt(),
          required(:lines) => [String.t()]
        }

  @type flow_result :: %{
          required(:request) => DecisionRequest.t(),
          required(:rendered_prompt) => WonderToolPromptRenderer.rendered_prompt(),
          required(:decision) => SelectionHandler.wonder_decision(),
          required(:journaled?) => boolean()
        }

  @doc """
  Normalizes and renders a wonderTool multiple-choice request, including
  decision, permission, and clarification checkpoints.
  """
  @spec prepare(map()) :: {:ok, prepared()} | {:error, term()}
  def prepare(request) when is_map(request) do
    with {:ok, normalized_request} <- normalize_request(request) do
      rendered_prompt = WonderToolPromptRenderer.render(normalized_request)

      {:ok,
       %{
         request: normalized_request,
         rendered_prompt: rendered_prompt,
         lines: rendered_prompt.lines
       }}
    end
  end

  def prepare(_request), do: {:error, :request_must_be_map}

  @doc """
  Captures exactly one selection for a prepared or raw wonderTool request.

  Options are passed through to `SelectionHandler.capture/3`, including
  `:question_id` and `:selected_at_ms`.
  """
  @spec capture(prepared() | map(), SelectionHandler.selection_payload(), keyword() | map()) ::
          {:ok, SelectionHandler.wonder_decision()} | {:error, term()}
  def capture(request_or_prepared, selection_payload, options \\ [])

  def capture(%{request: request}, selection_payload, options) when is_map(request) do
    SelectionHandler.capture(request, selection_payload, options)
  end

  def capture(request, selection_payload, options) when is_map(request) do
    with {:ok, prepared} <- prepare(request) do
      capture(prepared, selection_payload, options)
    end
  end

  def capture(_request_or_prepared, _selection_payload, _options),
    do: {:error, :request_must_be_map}

  @doc """
  Runs the render-and-select flow and optionally appends the decision to a journal.

  Pass `journal_path: path` and `event_seq: seq` to persist the decision as a
  journal-ready `:wonder_decision` entry. Without `journal_path`, the flow stays
  pure and returns `journaled?: false`.
  """
  @spec run(map(), SelectionHandler.selection_payload(), keyword() | map()) ::
          {:ok, flow_result()} | {:error, term()}
  def run(request, selection_payload, options \\ [])

  def run(request, selection_payload, options) when is_map(request) do
    options = Map.new(options)

    with {:ok, prepared} <- prepare(request),
         {:ok, decision} <- capture(prepared, selection_payload, options),
         {:ok, journaled?} <- maybe_append_decision(decision, options) do
      {:ok,
       %{
         request: prepared.request,
         rendered_prompt: prepared.rendered_prompt,
         decision: decision,
         journaled?: journaled?
       }}
    end
  end

  def run(_request, _selection_payload, _options), do: {:error, :request_must_be_map}

  defp normalize_request(%{tool: :wonder_tool, type: :multiple_choice_decision} = request),
    do: {:ok, request}

  defp normalize_request(request), do: DecisionRequest.parse(request)

  defp maybe_append_decision(decision, %{journal_path: journal_path, event_seq: event_seq})
       when is_binary(journal_path) and is_integer(event_seq) do
    case Journal.append(journal_path, Map.put(decision, :event_seq, event_seq)) do
      :ok -> {:ok, true}
      {:error, reason} -> {:error, {:journal_append_failed, reason}}
    end
  end

  defp maybe_append_decision(_decision, %{journal_path: journal_path})
       when is_binary(journal_path) do
    {:error, :event_seq_required_for_journaled_wonder_decision}
  end

  defp maybe_append_decision(_decision, _options), do: {:ok, false}
end
