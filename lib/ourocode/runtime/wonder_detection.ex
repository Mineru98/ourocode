defmodule Ourocode.Runtime.WonderDetection do
  @moduledoc """
  Folds wonderTool detections into loop binding state.
  """

  alias Ourocode.WonderTool.InteractionDetector

  @spec apply(map(), map()) :: map()
  def apply(state, runtime_event) when is_map(state) and is_map(runtime_event) do
    case InteractionDetector.detect(detector_payload(runtime_event)) do
      {:ok, detection} -> Map.put(state, :wonder, detection)
      :ignore -> state
    end
  rescue
    _exception -> state
  end

  def apply(state, _runtime_event), do: state

  defp detector_payload(event) when is_map(event) do
    case Map.get(event, :payload, event) do
      payload when is_map(payload) -> payload
      _other -> event
    end
  end
end
