defmodule Ourocode.Terminal.FooterRuntimeState do
  @moduledoc """
  Runtime status projection for the terminal footer.

  Footer rendering needs a compact view of runtime, stream, journal, transport,
  and replay state. Keeping that projection here prevents the renderer from
  owning state-shape fallback rules.
  """

  @type projected :: %{
          required(:runtime_status) => atom() | String.t(),
          required(:stream_status) => atom() | String.t(),
          required(:journal_status) => atom() | String.t(),
          required(:transport_statuses) => [String.t()],
          required(:replayable?) => boolean()
        }

  @doc """
  Builds footer runtime status from startup, context, and runtime state.
  """
  @spec project(map(), map(), map()) :: projected()
  def project(startup_result, context, runtime)
      when is_map(startup_result) and is_map(context) and is_map(runtime) do
    %{
      runtime_status: status(runtime, :unknown),
      stream_status: stream_status(startup_result, context, runtime),
      journal_status: journal_status(startup_result, context, runtime),
      transport_statuses: transport_statuses(startup_result, context, runtime),
      replayable?: replayable?(startup_result, context, runtime)
    }
  end

  @doc """
  Formats transport statuses for compact footer text.
  """
  @spec transport_text([String.t()]) :: String.t()
  def transport_text([]), do: "none"
  def transport_text(transport_statuses), do: Enum.join(transport_statuses, ",")

  defp stream_status(startup_result, context, runtime) do
    status(
      Map.get(runtime, :stream) || Map.get(context, :stream) || Map.get(startup_result, :stream),
      :unknown
    )
  end

  defp journal_status(startup_result, context, runtime) do
    status(
      Map.get(runtime, :journal) || Map.get(context, :journal) ||
        Map.get(startup_result, :journal),
      :unknown
    )
  end

  defp status(%{status: status}, _default)
       when (is_atom(status) and not is_nil(status)) or is_binary(status),
       do: status

  defp status(status, _default)
       when (is_atom(status) and not is_nil(status)) or is_binary(status),
       do: status

  defp status(_value, default), do: default

  defp transport_statuses(startup_result, context, runtime) do
    (transport_entries(startup_result) ++ transport_entries(context) ++ transport_entries(runtime))
    |> Enum.map(&transport_status/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp transport_entries(%{transports: transports}) when is_list(transports), do: transports
  defp transport_entries(%{"transports" => transports}) when is_list(transports), do: transports
  defp transport_entries(_state), do: []

  defp transport_status(%{type: type, status: status}), do: "#{type}:#{status}"
  defp transport_status(%{"type" => type, "status" => status}), do: "#{type}:#{status}"
  defp transport_status(type) when is_atom(type) or is_binary(type), do: "#{type}:unknown"
  defp transport_status(_transport), do: ""

  defp replayable?(startup_result, context, runtime) do
    replayable_value(startup_result) || replayable_value(context) || replayable_value(runtime) ||
      false
  end

  defp replayable_value(%{replayable?: replayable?}) when is_boolean(replayable?), do: replayable?

  defp replayable_value(%{"replayable?" => replayable?}) when is_boolean(replayable?),
    do: replayable?

  defp replayable_value(_state), do: nil
end
